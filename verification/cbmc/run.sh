#!/usr/bin/env bash
# CBMC bounded model checking of SDL's own C library (src/stdlib/).
#
#   verification/cbmc/run.sh [harness ...]      check the named harnesses (default: all)
#
# Each harness/<name>.c is compiled with goto-cc together with the SDL sources its
# "CBMC-SOURCES:" line names, and checked by cbmc with the unwind bound on its "CBMC-UNWIND:"
# line. Three kinds of run, each compared with EXPECT:
#
#   fixed    this working tree. Normally "pass".
#   base     the pre-fix tree at $CBMC_BASE (default cb6224d2e, the commit the findings were
#            made on). "fail:<regex>" when a finding the harness covers is present there.
#   mutant   each line of MUTANTS: a sed expression applied to a copy of this tree. It must make the
#            harness it names fail on the property its regex matches, which shows that the
#            property can fail at all (PLAN.md, "Every property must be able to fail").
#
# A "fail:<regex>" expectation matches the CBMC property lines that report FAILURE, which look
# like "[StepUTF8.pointer_dereference.12] line 226 dereference failure: pointer outside object
# bounds in str[...]: FAILURE". Logs go to build-cbmc/logs/, a summary to build-cbmc/REPORT.md.
# Exits non-zero if any outcome differs from EXPECT.
#
# SDL is configured with include/build_config/SDL_build_config_minimal.h (via
# verification/cbmc/include/SDL_build_config.h): no HAVE_* libc macros, so SDL_string.c compiles
# SDL's own strlcpy, strtol, ... instead of forwarding to the platform libc.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
here="$root/verification/cbmc"
out="$root/build-cbmc"
base_rev=${CBMC_BASE:-cb6224d2e}
base_sha=$(git -C "$root" rev-parse --verify "$base_rev^{commit}")
mkdir -p "$out/logs"

command -v cbmc > /dev/null || { echo "cbmc not on PATH: enter the dev shell (direnv allow, or nix develop)"; exit 1; }

# The checks every harness runs with. Unsigned wrap-around is defined behaviour and SDL relies
# on it (e.g. 0ULL - value), so --unsigned-overflow-check is not used; conversions likewise.
checks=(--bounds-check --pointer-check --pointer-overflow-check --pointer-primitive-check
  --signed-overflow-check --undefined-shift-check --div-by-zero-check --unwinding-assertions
  --object-bits 12) # SDL_string.c has more static objects than the default 2^8
# goto-cc preprocesses with the host compiler; SDL_intrin.h would pull in arm_neon.h, which
# CBMC's C front end cannot parse.
cflags=(-DSDL_DISABLE_NEON -DSDL_DISABLE_SVE2 -DSDL_DISABLE_SSE -DSDL_DISABLE_MMX)

# --- the base tree: src/ and include/ exported from git, never edited
base_src="$out/src-base"
if [ "$(cat "$base_src/.commit" 2>/dev/null || true)" != "$base_sha" ]; then
  rm -rf "$base_src"
  mkdir -p "$base_src"
  git -C "$root" archive "$base_sha" src include | tar -x -C "$base_src"
  echo "$base_sha" > "$base_src/.commit"
fi

header() { # <harness file> <key>
  sed -n "s/^ \* CBMC-$2: *//p" "$1" | head -1
}

# check <tree root> <harness name> <log> -> prints "pass" or "fail" plus the failed properties
check() {
  local tree=$1 name=$2 log=$3
  local h="$here/harness/$name.c"
  local srcs=() s
  for s in $(header "$h" SOURCES); do srcs+=("$tree/$s"); done
  local unwind; unwind=$(header "$h" UNWIND)
  local goto="${log%.log}.goto"
  if ! goto-cc "${cflags[@]}" -I"$here/include" -I"$tree/include" -I"$tree/src" -I"$here/harness" \
      "${srcs[@]}" "$h" -o "$goto" > "$log" 2>&1; then
    echo "compile-error"; return
  fi
  # "CBMC-REPLACE: f:g" swaps calls to f for the harness's model g (goto-instrument).
  local r
  for r in $(header "$h" REPLACE); do
    if ! goto-instrument --replace-calls "$r" "$goto" "$goto" >> "$log" 2>&1; then
      echo "compile-error"; return
    fi
  done
  cbmc "$goto" --function harness "${checks[@]}" --unwind "${unwind:-8}" \
    ${CBMC_EXTRA:-} >> "$log" 2>&1 || true
  if grep -q "^VERIFICATION SUCCESSFUL" "$log"; then
    echo "pass"
  elif grep -q "^VERIFICATION FAILED" "$log"; then
    echo "fail"
  else
    echo "error"
  fi
}

matches() { # <outcome> <expectation> <log>
  local outcome=$1 want=$2 log=$3
  case "$want" in
    pass) [ "$outcome" = pass ] ;;
    fail:*) [ "$outcome" = fail ] && grep -E ": FAILURE$" "$log" | grep -Eq -- "${want#fail:}" ;;
    *) return 1 ;;
  esac
}

report="$out/REPORT.md"
{
  echo "# CBMC report"
  echo
  echo "base \`${base_sha:0:9}\`, HEAD \`$(git -C "$root" rev-parse --short HEAD)\`, $(cbmc --version | head -1 | sed 's/^/cbmc /')"
  echo
  echo "| run | harness | outcome | expected | result |"
  echo "|---|---|---|---|---|"
} > "$report"

status=0
record() { # <run> <harness> <outcome> <expected> <log>
  local verdict=ok
  if ! matches "$3" "$4" "$5"; then verdict=MISMATCH; status=1; fi
  printf '  %-8s %-32s %-14s %-11s expected %s\n' "$verdict" "$1" "$2" "$3" "$4"
  if [ "$verdict" = MISMATCH ]; then
    { grep -E ": FAILURE$|^VERIFICATION|error|ERROR" "$5" || tail -3 "$5"; } | head -8 | sed 's/^/             /'
  fi
  echo "| $1 | $2 | $3 | \`$4\` | $verdict |" >> "$report"
}

wanted=("$@")
selected() { [ ${#wanted[@]} -eq 0 ] || printf '%s\n' "${wanted[@]}" | grep -qx "$1"; }

# Every check runs as a background job (at most $CBMC_JOBS at once; CBMC itself is
# single-threaded) and leaves its outcome in <log>.outcome. Results are recorded in order once
# all jobs are done. runs[] holds "<run> <harness> <expectation> <log>", tab-separated (the
# expectations are regexes and may contain '|').
tab=$'\t'
# Default 2: utf8strlcpy needs about 6 GB and strtol/steputf8 a few GB each; one job per core ran
# the development machine out of memory.
jobs_max=${CBMC_JOBS:-2}
runs=()
launch() { # <tree> <harness> <log> [tree to delete afterwards]
  while [ "$(jobs -rp | wc -l)" -ge "$jobs_max" ]; do wait -n || true; done
  rm -f "$3.outcome"
  ( check "$1" "$2" "$3" > "$3.outcome"; if [ -n "${4:-}" ]; then rm -rf "$4"; fi ) &
}

# --- harnesses: fixed and base tree
while read -r name base fixed; do
  case "$name" in ''|'#'*) continue ;; esac
  selected "$name" || continue
  [ -f "$here/harness/$name.c" ] || { echo "  MISSING  harness/$name.c"; status=1; continue; }
  launch "$root" "$name" "$out/logs/fixed-$name.log"
  launch "$base_src" "$name" "$out/logs/base-$name.log"
  runs+=("fixed${tab}$name${tab}$fixed${tab}$out/logs/fixed-$name.log"
    "base${tab}$name${tab}$base${tab}$out/logs/base-$name.log")
done < "$here/EXPECT"

# --- mutants: one sed expression (sed -E) applied to one file of a copy of this tree
while read -r m target file want expr; do
  case "$m" in ''|'#'*) continue ;; esac
  selected "$target" || selected "$m" || continue
  tree="$out/mutant-$m"
  rm -rf "$tree"; mkdir -p "$tree"
  cp -R "$root/src" "$root/include" "$tree/"
  sed -E "$expr" "$root/$file" > "$tree/$file"
  log="$out/logs/mutant-$m.log"
  if cmp -s "$root/$file" "$tree/$file"; then
    echo "not-applied" > "$log.outcome"; echo "the sed expression no longer changes $file" > "$log"
    rm -rf "$tree"
  else
    launch "$tree" "$target" "$log" "$tree"
  fi
  runs+=("mutant:$m${tab}$target${tab}$want${tab}$log")
done < "$here/MUTANTS"

echo "running ${#runs[@]} checks, $jobs_max at a time"
wait

for r in "${runs[@]}"; do
  IFS=$tab read -r run name want log <<< "$r"
  record "$run" "$name" "$(cat "$log.outcome")" "$want" "$log"
done

echo
if [ $status -eq 0 ]; then echo "all outcomes match EXPECT ($report)"; else echo "outcomes differ from EXPECT ($report)"; fi
exit $status
