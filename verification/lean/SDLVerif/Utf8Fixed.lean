import SDLVerif.Utf8String

/-
The fork's fixed UTF-8 code (bgyss/SDL, 2026-11-05), as it now is in src/stdlib/SDL_string.c:
* `StepUTF8` is `cFixed` (Utf8.lean): each trailing byte is read only after the previous one
  checked out, and 4-byte results stop at U+10FFFF (F-004, F-005).
* `SDL_utf8strlcpy` is `fixLcpy` (Utf8String.lean): the backward scan includes index 0 (F-007).
* `SDL_StepBackUTF8` is `cStepBackFix` below (F-008).

The pre-fix models (`cStep`, `cLcpy`, `cStepBack`) stay as the record of the findings; the
differential tests (test/utf8_diff.sh, test/utf8_corpus.sh) now run against these.
-/
namespace SDLVerif.Utf8

/-- The fixed `StepUTF8(&p, slen)` at offset `i`. -/
def stepAtF (s : Bytes) (i slen : Nat) : Res :=
  cFixed (byteAt s i) (byteAt s (i + 1)) (byteAt s (i + 2)) (byteAt s (i + 3)) (BitVec.ofNat 64 slen)

/-- The fixed `SDL_StepBackUTF8`:
```c
const char *decoded = str;
const Uint32 result = StepUTF8(&decoded, length);
if (result != 0 && (size_t)(decoded - str) != length) { *pstr -= 1; return SDL_INVALID_UNICODE_CODEPOINT; }
*pstr = str;
return result;
``` -/
def cStepBackFix (s : Bytes) (p : Nat) : CP × Nat :=
  if p = 0 then (0, 0)
  else
    let q := walkBack s p
    let r := stepAtF s q (p - q)
    if r.cp ≠ 0 ∧ r.adv.toNat ≠ p - q then (invalid, p - 1) else (r.cp, q)

/-- The fixed `StepUTF8` agrees with the old one wherever the old one returned an in-range
code point (from the patch audit `fix_changes_only_out_of_range`). -/
theorem cFixed_eq_of_in_range (b0 b1 b2 b3 : Byte) (slen : Size)
    (h : ¬ (cStep b0 b1 b2 b3 slen).cp > 0x10FFFF) :
    (cFixed b0 b1 b2 b3 slen).cp = (cStep b0 b1 b2 b3 slen).cp ∧
    (cFixed b0 b1 b2 b3 slen).adv = (cStep b0 b1 b2 b3 slen).adv :=
  (fix_changes_only_out_of_range b0 b1 b2 b3 slen).2 h

/-- The fixed forward step on an encoded scalar value: as `step_enc`. -/
theorem stepF_enc (pre post : Bytes) (c : CP) (slen : Nat) (hc : scalar c = true)
    (hs : (encL c).length ≤ slen) (h64 : slen < 2 ^ 64) :
    (stepAtF (pre ++ encL c ++ post) pre.length slen).cp = c ∧
    (stepAtF (pre ++ encL c ++ post) pre.length slen).adv.toNat = (encL c).length := by
  obtain ⟨h1, h2⟩ := step_enc pre post c slen hc hs h64
  have hr : ¬ (stepAt (pre ++ encL c ++ post) pre.length slen).cp > 0x10FFFF := by
    rw [h1]; simp only [scalar, Bool.and_eq_true, decide_eq_true_eq] at hc
    intro h; exact absurd hc.1.2 (by
      simp only [Bool.not_eq_true', Bool.and_eq_true, decide_eq_true_eq, not_and] at *
      bv_decide)
  obtain ⟨e1, e2⟩ := cFixed_eq_of_in_range _ _ _ _ _ hr
  exact ⟨by simpa [stepAtF, stepAt] using e1.trans h1, by
    have := congrArg BitVec.toNat e2; simp only [stepAtF, stepAt] at this ⊢; rw [this]; exact h2⟩

/-- **F-008 fixed: no silent skips.** Every call either reports exactly one invalid byte
(U+FFFD, moving back one byte), or returns a character whose encoding is *exactly* the bytes it
stepped back over. -/
theorem stepBackFix_spec (s : Bytes) (p : Nat) (hp : 0 < p) :
    (cStepBackFix s p = (invalid, p - 1)) ∨
    ((cStepBackFix s p).2 = walkBack s p ∧
     (cStepBackFix s p).1 = (stepAtF s (walkBack s p) (p - walkBack s p)).cp ∧
     ((cStepBackFix s p).1 ≠ 0 →
       (stepAtF s (walkBack s p) (p - walkBack s p)).adv.toNat = p - walkBack s p)) := by
  unfold cStepBackFix
  rw [if_neg (by omega)]
  simp only
  split
  · left; rfl
  · rename_i h
    right
    refine ⟨rfl, rfl, fun hne => ?_⟩
    exact Classical.byContradiction fun hadv => h ⟨by simpa using hne, hadv⟩

/-- **F-008 fixed, soundness against RFC 3629.** A non-zero, non-U+FFFD result is one
well-formed character that spans every byte stepped back over. -/
theorem stepBackFix_sound (s : Bytes) (p : Nat) (hp : 0 < p) (h64 : p < 2 ^ 64)
    (h0 : (cStepBackFix s p).1 ≠ 0) (hi : (cStepBackFix s p).1 ≠ invalid) :
    let q := (cStepBackFix s p).2
    (wfLen (byteAt s q) (byteAt s (q + 1)) (byteAt s (q + 2)) (byteAt s (q + 3))).toNat = p - q ∧
    decodeVal (wfLen (byteAt s q) (byteAt s (q + 1)) (byteAt s (q + 2)) (byteAt s (q + 3)))
      (byteAt s q) (byteAt s (q + 1)) (byteAt s (q + 2)) (byteAt s (q + 3)) = (cStepBackFix s p).1 := by
  intro q
  rcases stepBackFix_spec s p hp with h | ⟨hq, hcp, hadv⟩
  · exact absurd (by rw [h]) hi
  · have hq' : q = walkBack s p := hq
    have hcp' := hcp; rw [← hq'] at hcp'
    have hadv' := hadv h0; rw [← hq'] at hadv'
    have e0 : (stepAtF s q (p - q)).cp ≠ 0 := by rw [← hcp']; exact h0
    have ei : (stepAtF s q (p - q)).cp ≠ invalid := by rw [← hcp']; exact hi
    have hs := fixed_sound (byteAt s q) (byteAt s (q + 1)) (byteAt s (q + 2)) (byteAt s (q + 3))
      (BitVec.ofNat 64 (p - q)) e0 ei
    refine ⟨?_, ?_⟩
    · rw [hs.1]; simpa only [stepAtF] using hadv'
    · rw [hs.2]; simpa only [stepAtF] using hcp'.symm

/-- The fixed `StepBack` still inverts `Step` on every well-formed character. -/
theorem stepBackFix_enc (pre post : Bytes) (c : CP) (hc : scalar c = true) :
    cStepBackFix (pre ++ encL c ++ post) (pre.length + (encL c).length) = (c, pre.length) := by
  have hl := encL_length_pos c
  obtain ⟨h1, h2⟩ := stepF_enc pre post c (encL c).length hc (Nat.le_refl _) (by omega)
  have hc0 : c ≠ 0 := by intro h; simp [scalar, h] at hc
  unfold cStepBackFix
  rw [if_neg (by omega), walkBack_enc]
  simp only [Nat.add_sub_cancel_left, h1, h2, ne_eq, not_true_eq_false, and_false, ↓reduceIte]

end SDLVerif.Utf8
