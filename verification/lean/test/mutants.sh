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
  "stepbackfix_no_span_check|Utf8Fixed|s/if r.adv.toNat ≠ p - q ∧ \(r.cp ≠ 0 ∨ p - q ≠ 1\) then/if False then/"
  "stepbackfix_f026_nul_skips|Utf8Fixed|s/if r.adv.toNat ≠ p - q ∧ \(r.cp ≠ 0 ∨ p - q ≠ 1\) then/if r.adv.toNat ≠ p - q ∧ r.cp ≠ 0 then/"
  "scanFix_keeps_partial|Utf8String|s/      \(if b ≠ trailingBytes \(byteAt s 0\) \+ 1 then 0 else b\)/      (if b ≠ trailingBytes (byteAt s 0) + 1 then b else b)/"
  # Rect.lean: the integer rect functions and the F-012/F-015 fixes
  "guard_no_negative_bound|Rect|s/\(fixed \&\& \(r.w.sle HALF_MIN \|\| r.h.sle HALF_MIN\)\)/(fixed \&\& false)/"
  "inter_no_clamp|Rect|s/let d := if d.slt \(wide INT_MIN\) then wide INT_MIN else d/let d := d/"
  "inter_takes_min_origin|Rect|s/let amin := if a.slt b then b else a/let amin := if a.slt b then a else b/"
  "union_no_span_check|Rect|s/if fixed \&\& \(wide INT_MAX\).slt \(wide amax - wide amin\) then/if false then/"
  "union_off_by_one|Rect|s/else \(amin, amax - amin, false/else (amin, amax - amin + 1, false/"
  "enclose_no_span_check|Rect|s/else if fixed \&\& \(\(wide INT_MAX\)/else if false \&\& ((wide INT_MAX)/"
  "enclose_else_if_drops_max|Rect|0,/\(if px.slt a.minx then a.maxx else if a.maxx.slt px then px else a.maxx\)/s//(if px.slt a.minx then a.maxx else a.maxx)/"
  # RectLine.lean: Cohen-Sutherland line clipping
  "clip_top_to_bottom_edge|RectLine|s/  if o.top then \(ix s b.y1, b.y1\)/  if o.top then (ix s b.y2, b.y2)/"
  "interp_wrong_base|RectLine|s/def ix \(s : Seg\) \(y : Int\) : Int := s.x1 \+/def ix (s : Seg) (y : Int) : Int := s.x2 +/"
  # Header.lean: BMP/WAV header arithmetic (F-023/F-024)
  "int_max_is_uint_max|Header|s/def INT_MAX : Nat := 2147483647/def INT_MAX : Nat := 4294967295/"
  "pitch_not_aligned|Header|s/def rgbPitch \(w : Nat\) \(bitsPP : Nat\) : Nat := \(rawPitch w bitsPP \+ 3\) \/ 4 \* 4/def rgbPitch (w : Nat) (bitsPP : Nat) : Nat := rawPitch w bitsPP/"
  # GamepadMapping.lean: the mapping-string parser (F-006 bound, spaces, F-025 report)
  "gamepad_prefix_f006_bound|GamepadMapping|s/    if st.i ≥ GAME_SIZE - 1 then .inr st.binds/    if st.i ≥ GAME_SIZE then .inr st.binds/"
  "gamepad_spaces_are_chars|GamepadMapping|s/  else if c = ' ' then .inl st/  else if False then .inl st/"
  "report_no_separator|GamepadMapping|s/  else stored \+\+ \(if stored ≠ \[\] ∧ stored.getLast\? ≠ some ',' then \[','\] else \[\]\) \+\+/  else stored ++ ([] : List Char) ++/"
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
