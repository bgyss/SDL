#!/usr/bin/env bash
# Proof mutation test: every mutant below breaks the C model or the RFC 3629 spec in
# SDLVerif/Utf8.lean, and at least one theorem must then fail. A mutant that still checks means
# the theorems don't constrain that part of the code (a vacuous or too-weak spec).
#
# Run from verification/lean inside the dev shell: test/mutants.sh
set -euo pipefail
src=SDLVerif/Utf8.lean
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# name | sed expression (applied to the whole file)
mutants=(
  "no_overlong_check_2byte|s/if result ≥ 0x80 then mk result 2 2/if true then mk result 2 2/"
  "no_surrogate_check|s/(result < 0xD800 \|\| result > 0xDFFF)/true/"
  "four_byte_needs_only_3|0,/octet \&\&\& 0xF8 == 0xF0 \&\& slen ≥ 4/s//octet \&\&\& 0xF8 == 0xF0 \&\& slen ≥ 3/"
  "wrong_cont_mask|s/Bool := b \&\&\& 0xC0 == 0x80/Bool := b \&\&\& 0x80 == 0x80/"
  "invalid_advances_two|s/  else mk invalid 1 1/  else mk invalid 2 1/"
  "spec_f4_allows_9x|s/b0 == 0xF4 \&\& inR b1 0x80 0x8F/b0 == 0xF4 \&\& inR b1 0x80 0x9F/"
  "fix_drops_range_check|s/result ≥ 0x10000 \&\& result ≤ 0x10FFFF/result ≥ 0x10000/"
)

status=0
for m in "${mutants[@]}"; do
  name=${m%%|*}; expr=${m#*|}
  sed -E "$expr" "$src" > "$tmp/$name.lean"
  if cmp -s "$src" "$tmp/$name.lean"; then
    echo "  BROKEN  $name: sed expression did not change the file"; status=1; continue
  fi
  if lake env lean "$tmp/$name.lean" > "$tmp/$name.out" 2>&1; then
    echo "  MISSED  $name: all theorems still check"; status=1
  else
    echo "  caught  $name ($(grep -c '^.*error:' "$tmp/$name.out" || true) errors)"
  fi
done
exit $status
