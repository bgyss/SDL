#!/usr/bin/env bash
# Reproduces every finding in verification/FINDINGS.md on real ASan + UBSan builds of SDL, and
# checks that the fix in the current tree removes it.
#
#   verification/repro/run.sh [program ...]
#
# Two SDL trees are built from source with the same flags:
#   base   the pre-fix sources, exported from git at $REPRO_BASE (default cb6224d2e, the
#          commit the findings were made on; its src/ equals upstream 87f0e4a25)
#   fixed  this working tree
# Every program in this directory is built against both and run. Its outcome on each tree must
# match the line for it in EXPECT. Logs go to build-repro/logs/<tree>/<program>.log, and a
# summary to build-repro/REPORT.md. Exits non-zero if any outcome differs from EXPECT.
#
# Environment: REPRO_BASE (base commit), REPRO_ROUNDS (rounds for the two race programs,
# default: each program's own), REPRO_JOBS (parallel build jobs).
set -euo pipefail

root=$(git rev-parse --show-toplevel)
here="$root/verification/repro"
out="$root/build-repro"
base_rev=${REPRO_BASE:-cb6224d2e}
base_sha=$(git -C "$root" rev-parse --verify "$base_rev^{commit}")
head_sha=$(git -C "$root" rev-parse HEAD)
dirty=$(git -C "$root" status --porcelain -- src include | head -1)
mkdir -p "$out"

# Every UBSan check aborts, except pointer-overflow: it is reported and the program goes on, so
# that an out-of-bounds read that follows the bad pointer (F-009, F-013) still reaches ASan.
san="-g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined -fsanitize-recover=pointer-overflow"
if [ "$(uname -s)" = Darwin ]; then
  # Apple clang: the nix clang's ASan runtime hangs at startup on macOS 27 (TRUSTED_BASE.md).
  dev=$(env -u DEVELOPER_DIR xcode-select -p)
  tool() { env -u SDKROOT DEVELOPER_DIR="$dev" "$@"; }
  cc=(-DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_OBJC_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++)
else
  tool() { "$@"; }
  cc=(-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++)
fi

# --- the base tree: exported from git, never edited
base_src="$out/src-base"
if [ "$(cat "$base_src/.commit" 2>/dev/null || true)" != "$base_sha" ]; then
  rm -rf "$base_src"
  mkdir -p "$base_src"
  git -C "$root" archive "$base_sha" | tar -x -C "$base_src"
  echo "$base_sha" > "$base_src/.commit"
fi

build() { # <tree name> <SDL source>
  tool cmake -S "$here" -B "$out/$1" -G Ninja "${cc[@]}" -DCMAKE_BUILD_TYPE=Debug \
    -DSDL_SOURCE="$2" "-DCMAKE_C_FLAGS=$san" "-DCMAKE_OBJC_FLAGS=$san" \
    "-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined" > "$out/$1.configure.log" 2>&1 ||
    { tail -30 "$out/$1.configure.log"; exit 1; }
  tool cmake --build "$out/$1" -j "${REPRO_JOBS:-8}" > "$out/$1.build.log" 2>&1 ||
    { grep -E "error|Error" "$out/$1.build.log" | head -30; exit 1; }
}
echo "building base ($base_rev = ${base_sha:0:9}) and fixed (HEAD ${head_sha:0:9}${dirty:+ + uncommitted src changes})"
build base "$base_src"
build fixed "$root"

# --- expectations
declare -A finding base_exp fixed_exp
progs=()
while read -r prog id b f; do
  case "$prog" in ''|'#'*) continue ;; esac
  finding[$prog]=$id; base_exp[$prog]=$b; fixed_exp[$prog]=$f; progs+=("$prog")
done < "$here/EXPECT"
if [ $# -gt 0 ]; then progs=("$@"); fi

# check <log> <exit status> <expectation> -> prints a one-line observation, returns 0 on match
check() {
  local log=$1 rc=$2 exp=$3
  local asan ubsan
  asan=$(grep -m1 -oE "ERROR: AddressSanitizer: [a-z-]+" "$log" | sed 's/ERROR: AddressSanitizer: //' || true)
  ubsan=$(grep -m1 -E "runtime error:" "$log" | sed -E 's/^.*\/([^/]+:[0-9]+:[0-9]+): runtime error: /\1: /' || true)
  case "$exp" in
    ok|bug)
      local want_rc=0 tag=OK
      [ "$exp" = bug ] && want_rc=1 tag=BUG
      if [ -n "$asan" ]; then echo "ASan $asan"; return 1; fi
      if [ -n "$ubsan" ]; then echo "UBSan $ubsan"; return 1; fi
      local line; line=$(grep -m1 -E "^(OK|BUG):" "$log" || echo "no verdict, exit $rc")
      echo "$line"
      [ "$rc" = "$want_rc" ] && grep -q "^$tag:" "$log"
      ;;
    asan:*)
      local spec=${exp#asan:} kind frame
      kind=${spec%@*}; frame=${spec#*@}
      if [ -z "$asan" ]; then echo "no ASan report ($(grep -m1 -E '^(OK|BUG):' "$log" || echo "exit $rc"))"; return 1; fi
      local where; where=$(grep -m1 -E "^    #[0-9]+ .* in ${frame}" "$log" | sed -E 's/^ *#[0-9]+ 0x[0-9a-f]+ in //; s/ \(.*$//' || true)
      echo "ASan $asan in ${where:-?}"
      [[ "$asan" =~ ^($kind) ]] && [ -n "$where" ]
      ;;
    ubsan:*)
      local spec=${exp#ubsan:} text file
      text=${spec%@*}; file=${spec#*@}; text=${text//_/ }
      if [ -z "$ubsan" ]; then echo "no UBSan report ($(grep -m1 -E '^(OK|BUG):' "$log" || echo "exit $rc"))"; return 1; fi
      echo "UBSan $ubsan"
      grep -m1 -E "runtime error:" "$log" | grep -q "$file:.*runtime error: $text"
      ;;
    *) echo "bad expectation '$exp'"; return 1 ;;
  esac
}

report="$out/REPORT.md"
{
  echo "# Reproduction report"
  echo
  echo "- date: $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "- machine: $(uname -sm), $(sw_vers -productVersion 2>/dev/null || uname -r)"
  echo "- compiler: $(tool "${cc[0]#-DCMAKE_C_COMPILER=}" --version 2>/dev/null | head -1 || true)"
  echo "- base: \`$base_rev\` (${base_sha:0:12}), fixed: HEAD ${head_sha:0:12}${dirty:+ plus uncommitted src changes}"
  echo
  echo "| Program | Finding | Base (pre-fix) | Fixed |"
  echo "|---|---|---|---|"
} > "$report"

fail=0
for prog in "${progs[@]}"; do
  [ -n "${finding[$prog]:-}" ] || { echo "no EXPECT line for $prog"; fail=1; continue; }
  row="| \`$prog\` | ${finding[$prog]} |"
  for tree in base fixed; do
    exp=${base_exp[$prog]}; [ "$tree" = fixed ] && exp=${fixed_exp[$prog]}
    mkdir -p "$out/logs/$tree"
    log="$out/logs/$tree/$prog.log"
    rc=0
    ASAN_OPTIONS=halt_on_error=1:detect_leaks=0:allocator_may_return_null=1 \
      UBSAN_OPTIONS=print_stacktrace=1 \
      "$out/$tree/$prog" > "$log" 2>&1 || rc=$?
    if obs=$(check "$log" "$rc" "$exp"); then mark=pass; else mark=FAIL; fail=1; fi
    printf '%-6s %-22s %-6s %-5s %s\n' "$mark" "$prog" "${finding[$prog]}" "$tree" "$obs"
    obs=${obs//|/\\|}
    if [ "$mark" = pass ]; then row="$row $obs |"; else row="$row **FAIL** (expected \`$exp\`): $obs |"; fi
  done
  echo "$row" >> "$report"
done

echo
if [ $fail = 0 ]; then
  echo "all outcomes match EXPECT; report: $report"
  echo >> "$report"; echo "All outcomes match \`verification/repro/EXPECT\`." >> "$report"
else
  echo "some outcomes differ from EXPECT; report: $report"
  echo >> "$report"; echo "**Some outcomes differ from \`verification/repro/EXPECT\`.**" >> "$report"
fi
exit $fail
