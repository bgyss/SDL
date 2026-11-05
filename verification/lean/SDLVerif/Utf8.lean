import Std.Tactic.BVDecide

/-
UTF-8 decoding in SDL: `StepUTF8` (src/stdlib/SDL_string.c:192-257, commit cb6224d2e), behind
the public `SDL_StepUTF8` (`SDL_string.c:259-268`; contract in include/SDL3/SDL_stdinc.h:4204).

Method (see verification/PLAN.md, Phase 2):
* `cStep` is a line-by-line transcription of the C, using the C types: bytes are `BitVec 8`
  (Uint8), code points `BitVec 32` (Uint32), lengths `BitVec 64` (size_t). It also records how
  many bytes the C *reads*, which is not the same as how many it consumes.
* `wfLen` / `decodeVal` are written independently from RFC 3629 §4 (the byte-range grammar),
  not from SDL's bit tests, so the two can disagree.
* The theorems relate the two. `bv_decide` checks them over all 2^32 values of the four bytes
  and all 2^64 lengths.
* The model is tied back to the real C by differential testing (test/utf8_diff.sh).
-/
namespace SDLVerif.Utf8

abbrev Byte := BitVec 8
abbrev CP := BitVec 32
abbrev Size := BitVec 64

/-- `SDL_INVALID_UNICODE_CODEPOINT` -/
def invalid : CP := 0xFFFD

/-- Result of one step, packed as `cp (32) ++ adv (8) ++ reads (8)` so that one function holds
the whole control flow and `bv_decide` sees plain bit-vectors.
* `cp`: the return value
* `adv`: how far `*_str` moves
* `reads`: how many bytes from `str[0]` onwards the C code dereferences -/
abbrev Res := BitVec 48

def mk (cp : CP) (adv reads : Byte) : Res := cp ++ adv ++ reads
def Res.cp (r : Res) : CP := r.extractLsb' 16 32
def Res.adv (r : Res) : Byte := r.extractLsb' 8 8
def Res.reads (r : Res) : Byte := r.extractLsb' 0 8

def isCont (b : Byte) : Bool := b &&& 0xC0 == 0x80
def w (b : Byte) : CP := b.setWidth 32

/-- Transcription of `StepUTF8(&str, slen)`. `b0..b3` are `str[0..3]`. Bytes the C does not read
cannot affect the result; `reads` says which ones it does. -/
def cStep (b0 b1 b2 b3 : Byte) (slen : Size) : Res :=
  -- const Uint32 octet = (Uint32) (slen ? *str : 0);
  let octet : CP := if slen != 0 then w b0 else 0
  let r0 : Byte := if slen != 0 then 1 else 0
  if octet == 0 then mk 0 0 r0
  else if octet &&& 0x80 == 0 then mk octet 1 1
  else if octet &&& 0xE0 == 0xC0 && slen ≥ 2 then
    -- reads str[1]
    if isCont b1 then
      let result := ((octet &&& 0x1F) <<< 6) ||| (w b1 &&& 0x3F)
      if result ≥ 0x80 then mk result 2 2 else mk invalid 1 2
    else mk invalid 1 2
  else if octet &&& 0xF0 == 0xE0 && slen ≥ 3 then
    -- reads str[1], str[2] before checking either
    if isCont b1 && isCont b2 then
      let result := ((octet &&& 0x0F) <<< 12) ||| ((w b1 &&& 0x3F) <<< 6) ||| (w b2 &&& 0x3F)
      if result ≥ 0x800 && (result < 0xD800 || result > 0xDFFF) then mk result 3 3
      else mk invalid 1 3
    else mk invalid 1 3
  else if octet &&& 0xF8 == 0xF0 && slen ≥ 4 then
    -- reads str[1], str[2], str[3] before checking any of them
    if isCont b1 && isCont b2 && isCont b3 then
      let result := ((octet &&& 0x07) <<< 18) ||| ((w b1 &&& 0x3F) <<< 12)
                    ||| ((w b2 &&& 0x3F) <<< 6) ||| (w b3 &&& 0x3F)
      if result ≥ 0x10000 then mk result 4 4 else mk invalid 1 4
    else mk invalid 1 4
  else mk invalid 1 1

/-! ## RFC 3629 §4, written independently of the C

```
UTF8-1 = %x00-7F
UTF8-2 = %xC2-DF UTF8-tail
UTF8-3 = %xE0 %xA0-BF UTF8-tail / %xE1-EC 2( UTF8-tail ) /
         %xED %x80-9F UTF8-tail / %xEE-EF 2( UTF8-tail )
UTF8-4 = %xF0 %x90-BF 2( UTF8-tail ) / %xF1-F3 3( UTF8-tail ) /
         %xF4 %x80-8F 2( UTF8-tail )
UTF8-tail = %x80-BF
```
-/

def tail (b : Byte) : Bool := 0x80 ≤ b && b ≤ 0xBF
def inR (b lo hi : Byte) : Bool := lo ≤ b && b ≤ hi

/-- Length of the well-formed UTF-8 character at the start of `b0 b1 b2 b3`, or 0 if the input
does not start with one. -/
def wfLen (b0 b1 b2 b3 : Byte) : Byte :=
  if b0 ≤ 0x7F then 1
  else if inR b0 0xC2 0xDF && tail b1 then 2
  else if b0 == 0xE0 && inR b1 0xA0 0xBF && tail b2 then 3
  else if inR b0 0xE1 0xEC && tail b1 && tail b2 then 3
  else if b0 == 0xED && inR b1 0x80 0x9F && tail b2 then 3
  else if inR b0 0xEE 0xEF && tail b1 && tail b2 then 3
  else if b0 == 0xF0 && inR b1 0x90 0xBF && tail b2 && tail b3 then 4
  else if inR b0 0xF1 0xF3 && tail b1 && tail b2 && tail b3 then 4
  else if b0 == 0xF4 && inR b1 0x80 0x8F && tail b2 && tail b3 then 4
  else 0

/-- The scalar value a well-formed character of length `n` encodes (RFC 3629 §3). -/
def decodeVal (n : Byte) (b0 b1 b2 b3 : Byte) : CP :=
  if n == 1 then w b0
  else if n == 2 then ((w b0 &&& 0x1F) <<< 6) ||| (w b1 &&& 0x3F)
  else if n == 3 then ((w b0 &&& 0x0F) <<< 12) ||| ((w b1 &&& 0x3F) <<< 6) ||| (w b2 &&& 0x3F)
  else ((w b0 &&& 0x07) <<< 18) ||| ((w b1 &&& 0x3F) <<< 12) ||| ((w b2 &&& 0x3F) <<< 6)
       ||| (w b3 &&& 0x3F)

/-! ## What the C gets right -/

/-- Memory safety with a real length: the C never reads past `slen` bytes. -/
theorem reads_le_slen (b0 b1 b2 b3 : Byte) (slen : Size) :
    (cStep b0 b1 b2 b3 slen).reads.setWidth 64 ≤ slen := by
  unfold cStep mk Res.reads w isCont; bv_decide

/-- Progress: unless it returns 0 (end of string), each step consumes at least one byte, and
never more than it read. -/
theorem progress (b0 b1 b2 b3 : Byte) (slen : Size) :
    (cStep b0 b1 b2 b3 slen).cp ≠ 0 →
      1 ≤ (cStep b0 b1 b2 b3 slen).adv ∧
      (cStep b0 b1 b2 b3 slen).adv ≤ (cStep b0 b1 b2 b3 slen).reads := by
  unfold cStep mk Res.cp Res.adv Res.reads w isCont; bv_decide

/-- End of string: a NUL byte, or `slen == 0`, gives 0 and does not advance (header contract). -/
theorem stops_at_end (b0 b1 b2 b3 : Byte) (slen : Size) :
    (b0 = 0 ∨ slen = 0) →
      (cStep b0 b1 b2 b3 slen).cp = 0 ∧ (cStep b0 b1 b2 b3 slen).adv = 0 := by
  unfold cStep mk Res.cp Res.adv w isCont; bv_decide

/-- Completeness: every well-formed RFC 3629 character that fits in `slen` decodes to its
scalar value and consumes exactly its length. -/
theorem complete (b0 b1 b2 b3 : Byte) (slen : Size) :
    wfLen b0 b1 b2 b3 ≠ 0 → b0 ≠ 0 → (wfLen b0 b1 b2 b3).setWidth 64 ≤ slen →
      (cStep b0 b1 b2 b3 slen).cp = decodeVal (wfLen b0 b1 b2 b3) b0 b1 b2 b3 ∧
      (cStep b0 b1 b2 b3 slen).adv = wfLen b0 b1 b2 b3 := by
  unfold cStep wfLen decodeVal mk Res.cp Res.adv w isCont tail inR; bv_decide

/-- Soundness for in-range results: if the C returns a real character (not 0, not the
replacement character) at most U+10FFFF, the bytes it consumed are well-formed per RFC 3629 and
encode that character. -/
theorem sound_in_range (b0 b1 b2 b3 : Byte) (slen : Size) :
    (cStep b0 b1 b2 b3 slen).cp ≠ 0 → (cStep b0 b1 b2 b3 slen).cp ≠ invalid →
    (cStep b0 b1 b2 b3 slen).cp ≤ 0x10FFFF →
      wfLen b0 b1 b2 b3 = (cStep b0 b1 b2 b3 slen).adv ∧
      decodeVal (wfLen b0 b1 b2 b3) b0 b1 b2 b3 = (cStep b0 b1 b2 b3 slen).cp := by
  unfold cStep wfLen decodeVal mk Res.cp Res.adv w isCont tail inR invalid
  bv_decide

/-! ## What the C gets wrong (leads L-1 and L-2 in FINDINGS.md) -/

/-- L-2: the 4-byte branch has no upper bound, so `F5 80 80 80` decodes to 0x140000, which is
not a Unicode code point (RFC 3629 stops at U+10FFFF). -/
theorem accepts_out_of_range : (cStep 0xF5 0x80 0x80 0x80 4).cp = 0x140000 := by
  unfold cStep Res.cp mk w isCont; bv_decide

/-- L-2, exactly: the C returns a value above U+10FFFF iff the input is a 4-byte sequence with
lead F4–F7 that RFC 3629 rejects. Every such return is a wrong answer. -/
theorem out_of_range_iff (b0 b1 b2 b3 : Byte) (slen : Size) :
    (cStep b0 b1 b2 b3 slen).cp > 0x10FFFF ↔
      (inR b0 0xF4 0xF7 && isCont b1 && isCont b2 && isCont b3 && slen ≥ 4 &&
        wfLen b0 b1 b2 b3 == 0 &&
        decodeVal 4 b0 b1 b2 b3 > 0x10FFFF) := by
  unfold cStep wfLen decodeVal mk Res.cp w isCont tail inR invalid; bv_decide

/-- L-1: `SDL_StepUTF8(&p, NULL)` calls `StepUTF8(&p, 4)` (`SDL_string.c:262`). The header
says the string "_must_ be NULL-terminated, as the function will blindly read until it sees the
NULL char". For the 2-byte string `"\xF0"` (F0 then NUL) the C still reads 4 bytes, two past the
terminator. -/
theorem null_len_reads_past_nul : (cStep 0xF0 0x00 0xAA 0xAA 4).reads = 4 := by
  unfold cStep Res.reads mk w isCont; bv_decide

/-! ## A minimal fix, and exactly what it changes

`cFixed` is the smallest change that removes both problems:
* it reads each continuation byte only after the previous one checked out, so it stops at a NUL
* the 4-byte branch also requires `result ≤ 0x10FFFF`

This is a model only. Per the ground rules, `src/` is not edited here. -/

def cFixed (b0 b1 b2 b3 : Byte) (slen : Size) : Res :=
  let octet : CP := if slen != 0 then w b0 else 0
  let r0 : Byte := if slen != 0 then 1 else 0
  if octet == 0 then mk 0 0 r0
  else if octet &&& 0x80 == 0 then mk octet 1 1
  else if octet &&& 0xE0 == 0xC0 && slen ≥ 2 then
    if isCont b1 then
      let result := ((octet &&& 0x1F) <<< 6) ||| (w b1 &&& 0x3F)
      if result ≥ 0x80 then mk result 2 2 else mk invalid 1 2
    else mk invalid 1 2
  else if octet &&& 0xF0 == 0xE0 && slen ≥ 3 then
    if !isCont b1 then mk invalid 1 2
    else if !isCont b2 then mk invalid 1 3
    else
      let result := ((octet &&& 0x0F) <<< 12) ||| ((w b1 &&& 0x3F) <<< 6) ||| (w b2 &&& 0x3F)
      if result ≥ 0x800 && (result < 0xD800 || result > 0xDFFF) then mk result 3 3
      else mk invalid 1 3
  else if octet &&& 0xF8 == 0xF0 && slen ≥ 4 then
    if !isCont b1 then mk invalid 1 2
    else if !isCont b2 then mk invalid 1 3
    else if !isCont b3 then mk invalid 1 4
    else
      let result := ((octet &&& 0x07) <<< 18) ||| ((w b1 &&& 0x3F) <<< 12)
                    ||| ((w b2 &&& 0x3F) <<< 6) ||| (w b3 &&& 0x3F)
      if result ≥ 0x10000 && result ≤ 0x10FFFF then mk result 4 4 else mk invalid 1 4
  else mk invalid 1 1

/-- The fix is exactly RFC 3629: every non-replacement, non-zero result is a well-formed
character. Unlike `sound_in_range`, this needs no range side condition. -/
theorem fixed_sound (b0 b1 b2 b3 : Byte) (slen : Size) :
    (cFixed b0 b1 b2 b3 slen).cp ≠ 0 → (cFixed b0 b1 b2 b3 slen).cp ≠ invalid →
      wfLen b0 b1 b2 b3 = (cFixed b0 b1 b2 b3 slen).adv ∧
      decodeVal (wfLen b0 b1 b2 b3) b0 b1 b2 b3 = (cFixed b0 b1 b2 b3 slen).cp := by
  unfold cFixed wfLen decodeVal mk Res.cp Res.adv w isCont tail inR invalid
  bv_decide

theorem fixed_complete (b0 b1 b2 b3 : Byte) (slen : Size) :
    wfLen b0 b1 b2 b3 ≠ 0 → b0 ≠ 0 → (wfLen b0 b1 b2 b3).setWidth 64 ≤ slen →
      (cFixed b0 b1 b2 b3 slen).cp = decodeVal (wfLen b0 b1 b2 b3) b0 b1 b2 b3 ∧
      (cFixed b0 b1 b2 b3 slen).adv = wfLen b0 b1 b2 b3 := by
  unfold cFixed wfLen decodeVal mk Res.cp Res.adv w isCont tail inR; bv_decide

/-- The fix never reads past the first NUL. A NUL is never a continuation byte, so reading stops
at it. -/
theorem fixed_stops_at_nul (b0 b1 b2 b3 : Byte) :
    (b1 = 0 → (cFixed b0 b1 b2 b3 4).reads ≤ 2) ∧
    (b2 = 0 → (cFixed b0 b1 b2 b3 4).reads ≤ 3) := by
  unfold cFixed mk Res.reads w isCont; bv_decide

/-- Patch audit (the article's "prove which inputs a patch changes"): the fix returns the same
code point and advance as the C on every input, except where the C returns an out-of-range
value. There it returns U+FFFD and advances one byte, as the header's contract for invalid
sequences requires. -/
theorem fix_changes_only_out_of_range (b0 b1 b2 b3 : Byte) (slen : Size) :
    ((cStep b0 b1 b2 b3 slen).cp > 0x10FFFF →
      (cFixed b0 b1 b2 b3 slen).cp = invalid ∧ (cFixed b0 b1 b2 b3 slen).adv = 1) ∧
    (¬ (cStep b0 b1 b2 b3 slen).cp > 0x10FFFF →
      (cFixed b0 b1 b2 b3 slen).cp = (cStep b0 b1 b2 b3 slen).cp ∧
      (cFixed b0 b1 b2 b3 slen).adv = (cStep b0 b1 b2 b3 slen).adv) := by
  unfold cStep cFixed mk Res.cp Res.adv w isCont invalid; bv_decide

end SDLVerif.Utf8
