#!/usr/bin/env bash
# Proof mutation test: every mutant below breaks a C model or a spec in SDLVerif/, and at least
# one theorem must then fail. A mutant that still checks means the theorems don't constrain that
# part of the code (a vacuous or too-weak spec).
#
# Run from verification/lean inside the dev shell, after `lake build`: test/mutants.sh
set -euo pipefail
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# name | file | sed expression (applied to the whole file)
mutants=(
  # Utf8.lean: the StepUTF8 transcription and the RFC 3629 spec
  "no_overlong_check_2byte|Utf8|s/if result ≥ 0x80 then mk result 2 2/if true then mk result 2 2/"
  "no_surrogate_check|Utf8|s/(result < 0xD800 \|\| result > 0xDFFF)/true/"
  "four_byte_needs_only_3|Utf8|0,/octet \&\&\& 0xF8 == 0xF0 \&\& slen ≥ 4/s//octet \&\&\& 0xF8 == 0xF0 \&\& slen ≥ 3/"
  "wrong_cont_mask|Utf8|s/Bool := b \&\&\& 0xC0 == 0x80/Bool := b \&\&\& 0x80 == 0x80/"
  "invalid_advances_two|Utf8|s/  else mk invalid 1 1/  else mk invalid 2 1/"
  "spec_f4_allows_9x|Utf8|s/b0 == 0xF4 \&\& inR b1 0x80 0x8F/b0 == 0xF4 \&\& inR b1 0x80 0x9F/"
  "fix_drops_range_check|Utf8|s/result ≥ 0x10000 \&\& result ≤ 0x10FFFF/result ≥ 0x10000/"
  # Utf8Encode.lean: the SDL_UCS4ToUTF8 transcription
  "enc_no_surrogate_sanitize|Utf8Encode|s/else if 0xD800 ≤ c \&\& c ≤ 0xDFFF then invalid/else if false then invalid/"
  "enc_wrong_3byte_lead|Utf8Encode|s/mkE \(0xE0 \|\|\| bt/mkE (0xF0 ||| bt/"
  # Utf8String.lean: SDL_StepBackUTF8 and SDL_utf8strlcpy
  "walkback_one_step|Utf8String|s/  \| q \+ 1 => if isCont \(byteAt s q\) then walkBack s q else q/  | q + 1 => if isCont (byteAt s q) then q else q/"
  "scanC_checks_index0|Utf8String|0,/  \| 0 => b$/s//  | 0 => if trailingBytes (byteAt s 0) ≠ 0 then (if b ≠ trailingBytes (byteAt s 0) + 1 then 0 else b) else b/"
  # Utf8Fixed.lean: the fork's fixed SDL_StepBackUTF8
  "stepbackfix_no_span_check|Utf8Fixed|s/if r.cp ≠ 0 ∧ r.adv.toNat ≠ p - q then/if False then/"
  "scanFix_keeps_partial|Utf8String|s/      \(if b ≠ trailingBytes \(byteAt s 0\) \+ 1 then 0 else b\)/      (if b ≠ trailingBytes (byteAt s 0) + 1 then b else b)/"
)

status=0
for m in "${mutants[@]}"; do
  name=${m%%|*}; rest=${m#*|}; file=${rest%%|*}; expr=${rest#*|}
  src=SDLVerif/$file.lean
  sed -E "$expr" "$src" > "$tmp/$name.lean"
  if cmp -s "$src" "$tmp/$name.lean"; then
    echo "  BROKEN  $name: sed expression did not change $src"; status=1; continue
  fi
  if lake env lean "$tmp/$name.lean" > "$tmp/$name.out" 2>&1; then
    echo "  MISSED  $name ($file): all theorems still check"; status=1
  else
    echo "  caught  $name ($file, $(grep -c '^.*error:' "$tmp/$name.out" || true) errors)"
  fi
done
exit $status
