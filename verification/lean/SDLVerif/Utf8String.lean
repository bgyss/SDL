import SDLVerif.Utf8Encode

/-
String-level UTF-8 functions in SDL (src/stdlib/SDL_string.c, commit cb6224d2e):
* `SDL_StepBackUTF8` (:270-287), contract in include/SDL3/SDL_stdinc.h:4249-4278
* `SDL_utf8strlcpy` (:1045-1078), contract in include/SDL3/SDL_stdinc.h:3309-3335

A string is a `List Byte`. `stepAt s i slen` is `StepUTF8` at offset `i` (the byte-level `cStep`
from Utf8.lean). Reading past the end of the list gives 0. That never matters for the
results below: every theorem either has the real bytes in range or relies on
`reads_le_slen` / `adv_le_slen`, which show the C does not look further.

Results:
* `step_enc`, `stepBack_enc`, `stepBack_inverts_step`: on any well-formed character, wherever it
  sits in a string, `StepBack` exactly undoes `Step`.
* `decodeFwd_encodeAll`, `decodeBack_encodeAll`: decoding a whole well-formed string forwards
  gives its code points, backwards gives them reversed.
* `stepBack_skips_only_cont` (F-008): on invalid input, the only bytes `StepBack` jumps over
  without reporting U+FFFD are continuation bytes; `stepBack_swallows` is a concrete case.
* `lcpy_bounds`: `SDL_utf8strlcpy` never writes more than `dst_bytes` bytes, on any input.
* `fixLcpy_wf` / `lcpy_c_vs_fixed` (F-007): with the backward scan extended to index 0, the
  copy is exactly the longest prefix of whole characters that fits. The real C differs from that
  *if and only if* the cut falls inside the first character, at least 2 bytes in; then it keeps
  a truncated sequence, against the header's promise.
-/
namespace SDLVerif.Utf8

abbrev Bytes := List Byte

def byteAt (s : Bytes) (i : Nat) : Byte := s.getD i 0

/-- `StepUTF8(&p, slen)` with `p = s + i`. -/
def stepAt (s : Bytes) (i slen : Nat) : Res :=
  cStep (byteAt s i) (byteAt s (i + 1)) (byteAt s (i + 2)) (byteAt s (i + 3)) (BitVec.ofNat 64 slen)

/-- The bytes `SDL_UCS4ToUTF8` writes for `c`. -/
def encL (c : CP) : Bytes :=
  let e := cEncode c
  if e.n = 1 then [e.e0]
  else if e.n = 2 then [e.e0, e.e1]
  else if e.n = 3 then [e.e0, e.e1, e.e2]
  else [e.e0, e.e1, e.e2, e.e3]

/-- A string of characters: `SDL_UCS4ToUTF8` applied to each in turn. -/
def encodeAll (cs : List CP) : Bytes := cs.flatMap encL

/-! ### Byte-level facts about the encoder's output -/

theorem enc_cases (c : CP) :
    (cEncode c).n = 1 ∨ (cEncode c).n = 2 ∨ (cEncode c).n = 3 ∨ (cEncode c).n = 4 := by
  unfold cEncode sanitize mkE Enc.n bt invalid; bv_decide

/-- The lead byte is never a continuation byte, the others always are. -/
theorem enc_shape (c : CP) :
    isCont (cEncode c).e0 = false ∧
    ((cEncode c).n ≥ 2 → isCont (cEncode c).e1 = true) ∧
    ((cEncode c).n ≥ 3 → isCont (cEncode c).e2 = true) ∧
    ((cEncode c).n ≥ 4 → isCont (cEncode c).e3 = true) := by
  unfold cEncode sanitize mkE Enc.e0 Enc.e1 Enc.e2 Enc.e3 Enc.n bt invalid isCont; bv_decide

theorem encL_length (c : CP) : (encL c).length = (cEncode c).n.toNat := by
  rcases enc_cases c with h | h | h | h <;> simp [encL, h]

theorem encL_length_pos (c : CP) : 1 ≤ (encL c).length ∧ (encL c).length ≤ 4 := by
  rcases enc_cases c with h | h | h | h <;> simp [encL, h]

theorem byteAt_append (pre rest : Bytes) (j : Nat) :
    byteAt (pre ++ rest) (pre.length + j) = byteAt rest j := by
  simp [byteAt, List.getD_eq_getElem?_getD, List.getElem?_append_right]

theorem byteAt_append' (pre rest : Bytes) (i : Nat) (h : pre.length ≤ i) :
    byteAt (pre ++ rest) i = byteAt rest (i - pre.length) := by
  have : i = pre.length + (i - pre.length) := by omega
  rw [this, byteAt_append]; congr 1; omega

/-- `StepUTF8` with `slen == 0` returns 0 (end of string). -/
theorem cStep_slen0 (b0 b1 b2 b3 : Byte) : (cStep b0 b1 b2 b3 0).cp = 0 := by
  unfold cStep mk Res.cp w isCont; bv_decide

/-- The advance never exceeds `slen` (the C stays inside the length it was given). -/
theorem adv_le_slen (b0 b1 b2 b3 : Byte) (slen : Size) :
    (cStep b0 b1 b2 b3 slen).adv.setWidth 64 ≤ slen := by
  unfold cStep mk Res.adv w isCont; bv_decide

theorem ofNat_le_of_le {n : Byte} {m : Nat} (h1 : n.toNat ≤ m) (h2 : m < 2 ^ 64) :
    n.setWidth 64 ≤ BitVec.ofNat 64 m := by
  rw [BitVec.le_def, BitVec.toNat_setWidth, BitVec.toNat_ofNat]
  have : n.toNat < 2 ^ 8 := n.isLt
  rw [Nat.mod_eq_of_lt (by omega), Nat.mod_eq_of_lt h2]; exact h1

/-- Byte `t` of `SDL_UCS4ToUTF8`'s output. -/
def encByte (c : CP) : Nat → Byte
  | 0 => (cEncode c).e0
  | 1 => (cEncode c).e1
  | 2 => (cEncode c).e2
  | _ => (cEncode c).e3

theorem byteAt_encL (c : CP) (Q : Bytes) (t : Nat) (ht : t < (encL c).length) :
    byteAt (encL c ++ Q) t = encByte c t := by
  rcases enc_cases c with h | h | h | h <;> simp [encL, h] at ht ⊢ <;>
    (rcases t with _ | _ | _ | _ | t <;> simp_all [byteAt, encByte] <;> omega)

theorem n_ge_of_length (c : CP) (k : Nat) (hk : k < 256) (h : k ≤ (encL c).length) :
    (cEncode c).n ≥ BitVec.ofNat 8 k := by
  rw [encL_length] at h
  show BitVec.ofNat 8 k ≤ (cEncode c).n
  rw [BitVec.le_def, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hk]; exact h

/-- Bytes `1..n-1` of an encoded character are continuation bytes, byte 0 is not. -/
theorem encByte_cont (c : CP) (t : Nat) (h1 : 1 ≤ t) (h2 : t < (encL c).length) :
    isCont (encByte c t) = true := by
  obtain ⟨_, a1, a2, a3⟩ := enc_shape c
  have h4 := (encL_length_pos c).2
  rcases t with _ | _ | _ | _ | t
  · omega
  · exact a1 (n_ge_of_length c 2 (by decide) (by omega))
  · exact a2 (n_ge_of_length c 3 (by decide) (by omega))
  · exact a3 (n_ge_of_length c 4 (by decide) (by omega))
  · omega

theorem encByte_lead_not_cont (c : CP) : isCont (encByte c 0) = false := (enc_shape c).1

theorem byteAt_enc_mid (pre post : Bytes) (c : CP) (t : Nat) (ht : t < (encL c).length) :
    byteAt (pre ++ encL c ++ post) (pre.length + t) = encByte c t := by
  rw [List.append_assoc, byteAt_append, byteAt_encL c post t ht]

/-! ### Forward and backward steps over one well-formed character -/

/-- `StepUTF8` at the start of an encoded scalar value returns it and consumes exactly its
bytes, whatever precedes or follows it, for any slen that covers it. -/
theorem step_enc (pre post : Bytes) (c : CP) (slen : Nat) (hc : scalar c = true)
    (hs : (encL c).length ≤ slen) (h64 : slen < 2 ^ 64) :
    (stepAt (pre ++ encL c ++ post) pre.length slen).cp = c ∧
    (stepAt (pre ++ encL c ++ post) pre.length slen).adv.toNat = (encL c).length := by
  have hn : (cEncode c).n.toNat ≤ slen := by rw [← encL_length]; exact hs
  have hle := ofNat_le_of_le hn h64
  simp only [stepAt, List.append_assoc, byteAt_append]
  rcases enc_cases c with h | h | h | h
  · have hrt := enc_dec_roundtrip c (byteAt post 0) (byteAt post 1) (byteAt post 2) _ hc hle
    simp [encL, h, mem1, mem2, mem3, byteAt] at hrt ⊢; exact ⟨hrt.1, by rw [hrt.2]; rfl⟩
  · have hrt := enc_dec_roundtrip c 0 (byteAt post 0) (byteAt post 1) _ hc hle
    simp [encL, h, mem1, mem2, mem3, byteAt] at hrt ⊢; exact ⟨hrt.1, by rw [hrt.2]; rfl⟩
  · have hrt := enc_dec_roundtrip c 0 0 (byteAt post 0) _ hc hle
    simp [encL, h, mem1, mem2, mem3, byteAt] at hrt ⊢; exact ⟨hrt.1, by rw [hrt.2]; rfl⟩
  · have hrt := enc_dec_roundtrip c 0 0 0 _ hc hle
    simp [encL, h, mem1, mem2, mem3, byteAt] at hrt ⊢; exact ⟨hrt.1, by rw [hrt.2]; rfl⟩

/-! `SDL_StepBackUTF8(start, &p)`:
```c
if (!pstr || *pstr <= start) return 0;
const char *str = *pstr;
do { if (str == start) break; --str; } while ((*str & 0xC0) == 0x80);
size_t length = (*pstr - str);
*pstr = str;
return StepUTF8(&str, length);
```
-/

/-- The `do … while` loop: from offset `p`, the offset it stops at. -/
def walkBack (s : Bytes) : Nat → Nat
  | 0 => 0
  | q + 1 => if isCont (byteAt s q) then walkBack s q else q

/-- `SDL_StepBackUTF8(s, &p)`: the code point and the new offset. -/
def cStepBack (s : Bytes) (p : Nat) : CP × Nat :=
  if p = 0 then (0, 0)
  else
    let q := walkBack s p
    ((stepAt s q (p - q)).cp, q)

/-- The walk steps over continuation bytes and stops on the first byte that is not one. -/
theorem walkBack_over (s : Bytes) (m : Nat) (h0 : isCont (byteAt s m) = false) :
    ∀ k, (∀ t, 1 ≤ t → t ≤ k → isCont (byteAt s (m + t)) = true) → walkBack s (m + k + 1) = m
  | 0, _ => by simp [walkBack, h0]
  | k + 1, h => by
    rw [show m + (k + 1) + 1 = (m + k + 1) + 1 by omega, walkBack,
        if_pos (by have := h (k + 1) (by omega) (by omega); rwa [show m + (k + 1) = m + k + 1 by omega] at this)]
    exact walkBack_over s m h0 k (fun t a b => h t a (by omega))

/-- From the end of an encoded character, the walk stops at its lead byte. -/
theorem walkBack_enc (pre post : Bytes) (c : CP) :
    walkBack (pre ++ encL c ++ post) (pre.length + (encL c).length) = pre.length := by
  have hn := encL_length_pos c
  have e : pre.length + (encL c).length = pre.length + ((encL c).length - 1) + 1 := by omega
  rw [e]
  apply walkBack_over
  · have := byteAt_enc_mid pre post c 0 (by omega)
    simp only [Nat.add_zero] at this; rw [this]; exact encByte_lead_not_cont c
  · intro t a b; rw [byteAt_enc_mid pre post c t (by omega)]; exact encByte_cont c t a (by omega)

/-- `StepBack` from the end of an encoded scalar value returns it and moves to its start,
whatever bytes precede it (they need not even be valid UTF-8). -/
theorem stepBack_enc (pre post : Bytes) (c : CP) (hc : scalar c = true) :
    cStepBack (pre ++ encL c ++ post) (pre.length + (encL c).length) = (c, pre.length) := by
  have hl := encL_length_pos c
  unfold cStepBack
  rw [if_neg (by omega), walkBack_enc]
  have := (step_enc pre post c (encL c).length hc (Nat.le_refl _) (by omega)).1
  simp only [Nat.add_sub_cancel_left, this]

/-- **StepBack inverts Step** on every well-formed character: step forward over it from its
start, then back, and you are where you started with the same code point. -/
theorem stepBack_inverts_step (pre post : Bytes) (c : CP) (hc : scalar c = true)
    (h64 : (pre ++ encL c ++ post).length < 2 ^ 64) :
    let s := pre ++ encL c ++ post
    let r := stepAt s pre.length (s.length - pre.length)
    r.cp = c ∧ cStepBack s (pre.length + r.adv.toNat) = (r.cp, pre.length) := by
  intro s r
  have hs : s.length = pre.length + (encL c).length + post.length := by simp [s] <;> omega
  have h64' : s.length < 2 ^ 64 := h64
  have hlen : (encL c).length ≤ s.length - pre.length := by omega
  obtain ⟨hcp, hadv⟩ := step_enc pre post c (s.length - pre.length) hc hlen (by omega)
  exact ⟨hcp, by rw [show r.adv.toNat = (encL c).length from hadv, show r.cp = c from hcp];
                 exact stepBack_enc pre post c hc⟩

/-! ### Whole strings -/

/-- Loop `while ((cp = SDL_StepUTF8(&p, &slen)))` from offset `i`, collecting code points. -/
def decodeFwd (s : Bytes) (i : Nat) : Nat → List CP
  | 0 => []
  | fuel + 1 =>
    let r := stepAt s i (s.length - i)
    if r.cp = 0 then [] else r.cp :: decodeFwd s (i + r.adv.toNat) fuel

/-- Loop `while ((cp = SDL_StepBackUTF8(s, &p)))` from offset `p`. -/
def decodeBack (s : Bytes) (p : Nat) : Nat → List CP
  | 0 => []
  | fuel + 1 =>
    let r := cStepBack s p
    if r.1 = 0 then [] else r.1 :: decodeBack s r.2 fuel

theorem encodeAll_cons (c : CP) (cs : List CP) : encodeAll (c :: cs) = encL c ++ encodeAll cs := by
  simp [encodeAll]

theorem encodeAll_append (as bs : List CP) : encodeAll (as ++ bs) = encodeAll as ++ encodeAll bs := by
  simp [encodeAll, List.flatMap_append]

theorem decodeFwd_gen (cs : List CP) (pre : Bytes) (hcs : ∀ c ∈ cs, scalar c = true)
    (h64 : (pre ++ encodeAll cs).length < 2 ^ 64) :
    decodeFwd (pre ++ encodeAll cs) pre.length (cs.length + 1) = cs := by
  induction cs generalizing pre with
  | nil =>
    have h0 := cStep_slen0 (byteAt pre pre.length) (byteAt pre (pre.length + 1))
      (byteAt pre (pre.length + 2)) (byteAt pre (pre.length + 3))
    simp [decodeFwd, encodeAll, stepAt]; exact h0
  | cons c cs ih =>
    have hc := hcs c (by simp)
    rw [show (c :: cs).length + 1 = (cs.length + 1) + 1 from rfl, decodeFwd]
    have hl := encL_length_pos c
    rw [encodeAll_cons] at h64 ⊢
    have e : pre ++ (encL c ++ encodeAll cs) = pre ++ encL c ++ encodeAll cs := by simp
    rw [e] at h64 ⊢
    have hlen : (encL c).length ≤ (pre ++ encL c ++ encodeAll cs).length - pre.length := by
      simp <;> omega
    obtain ⟨hcp, hadv⟩ := step_enc pre (encodeAll cs) c _ hc hlen (by omega)
    have hc0 : c ≠ 0 := by
      intro h; simp [scalar, h] at hc
    simp only [hcp, hadv, if_neg hc0]
    congr 1
    have := ih (pre ++ encL c) (fun x hx => hcs x (by simp [hx])) (by simpa using h64)
    simpa [List.length_append] using this

/-- Decoding a well-formed string forwards gives back exactly its code points. -/
theorem decodeFwd_encodeAll (cs : List CP) (hcs : ∀ c ∈ cs, scalar c = true)
    (h64 : (encodeAll cs).length < 2 ^ 64) :
    decodeFwd (encodeAll cs) 0 (cs.length + 1) = cs := by
  simpa using decodeFwd_gen cs [] hcs (by simpa using h64)

theorem decodeBack_gen (rs : List CP) (post : Bytes) (hrs : ∀ c ∈ rs, scalar c = true) :
    decodeBack (encodeAll rs.reverse ++ post) (encodeAll rs.reverse).length (rs.length + 1) = rs := by
  induction rs generalizing post with
  | nil => simp [decodeBack, cStepBack, encodeAll]
  | cons c rs ih =>
    have hc := hcs_head hrs
    rw [show (c :: rs).length + 1 = (rs.length + 1) + 1 from rfl, decodeBack]
    simp only [List.reverse_cons, encodeAll_append]
    have e : encodeAll [c] = encL c := by simp [encodeAll]
    rw [e]
    have hstep := stepBack_enc (encodeAll rs.reverse) post c hc
    simp only [List.length_append, hstep]
    have hc0 : c ≠ 0 := by intro h; simp [scalar, h] at hc
    simp only [if_neg hc0]
    congr 1
    have := ih (encL c ++ post) (fun x hx => hrs x (by simp [hx]))
    simpa using this
where
  hcs_head {c : CP} {rs : List CP} (h : ∀ x ∈ c :: rs, scalar x = true) : scalar c = true :=
    h c (by simp)

/-- Decoding a well-formed string backwards with `SDL_StepBackUTF8` gives its code points in
reverse order. -/
theorem decodeBack_encodeAll (cs : List CP) (hcs : ∀ c ∈ cs, scalar c = true) :
    decodeBack (encodeAll cs) (encodeAll cs).length (cs.length + 1) = cs.reverse := by
  have := decodeBack_gen cs.reverse [] (by simpa using hcs)
  simpa using this

/-! ### F-008: what `StepBack` does on invalid input -/

/-- The walk moves back at least one byte, and every byte strictly between where it stops and
where it started is a continuation byte. -/
theorem walkBack_spec (s : Bytes) (p : Nat) (hp : 0 < p) :
    walkBack s p < p ∧ ∀ i, walkBack s p < i → i < p → isCont (byteAt s i) = true := by
  induction p with
  | zero => omega
  | succ q ih =>
    unfold walkBack
    by_cases hq : isCont (byteAt s q) = true
    · simp only [hq, if_true]
      by_cases h0 : q = 0
      · subst h0; simp [walkBack]; intro i a b; omega
      · obtain ⟨ih1, ih2⟩ := ih (by omega)
        refine ⟨by omega, fun i h1 h2 => ?_⟩
        by_cases hi : i = q
        · subst hi; exact hq
        · exact ih2 i h1 (by omega)
    · simp only [hq]; simp; intro i h1 h2; omega


/-- **F-008, exactly.** Each `StepBack` lands on offset `q` and decodes one character there
with length `p - q`, consuming `adv` of those bytes. When it returns a character (not 0), every
byte it jumps over beyond those `adv` (which it skips silently, where the header promises
U+FFFD for invalid sequences) is a continuation byte. Nothing else is ever skipped. -/
theorem stepBack_skips_only_cont (s : Bytes) (p : Nat) (hp : 0 < p) (h64 : p < 2 ^ 64) :
    let q := (cStepBack s p).2
    let r := stepAt s q (p - q)
    (cStepBack s p).1 = r.cp ∧ q < p ∧ r.adv.toNat ≤ p - q ∧
    (r.cp ≠ 0 → ∀ i, q + r.adv.toNat ≤ i → i < p → isCont (byteAt s i) = true) := by
  intro q r
  have hp0 : p ≠ 0 := by omega
  have hq : q = walkBack s p := by simp [q, cStepBack, hp0]
  obtain ⟨w1, w2⟩ := walkBack_spec s p hp
  have hadv : r.adv.toNat ≤ p - q := by
    have h := adv_le_slen (byteAt s q) (byteAt s (q + 1)) (byteAt s (q + 2)) (byteAt s (q + 3))
      (BitVec.ofNat 64 (p - q))
    rw [BitVec.le_def, BitVec.toNat_setWidth, BitVec.toNat_ofNat] at h
    have hb : r.adv.toNat < 2 ^ 8 := r.adv.isLt
    rw [Nat.mod_eq_of_lt (by omega), Nat.mod_eq_of_lt (by omega)] at h
    exact h
  refine ⟨by simp [r, cStepBack, hp0, q], by omega, hadv, ?_⟩
  intro hcp i h1 h2
  have hprog := (progress (byteAt s q) (byteAt s (q + 1)) (byteAt s (q + 2)) (byteAt s (q + 3))
    (BitVec.ofNat 64 (p - q)) hcp).1
  rw [BitVec.le_def] at hprog
  have h1' : 1 ≤ r.adv.toNat := by simpa [r, stepAt] using hprog
  exact w2 i (by omega) h2

/-- F-008, concretely: `"a\x80"` stepped back from the end returns `'a'` and lands at 0. The
stray `0x80` is skipped silently; stepping forward over the same bytes gives `'a'`, U+FFFD. -/
theorem stepBack_swallows :
    cStepBack [0x61, 0x80] 2 = (0x61, 0) ∧
    decodeFwd [0x61, 0x80] 0 3 = [0x61, invalid] := by
  decide

/-! ### `SDL_utf8strlcpy`

```c
bytes = SDL_min(src_bytes, dst_bytes - 1);
if (bytes) {
    unsigned char c = (unsigned char)src[bytes - 1];
    if (UTF8_IsLeadByte(c)) {               // C0..F4
        --bytes;
    } else if (UTF8_IsTrailingByte(c)) {    // 80..BF
        for (i = bytes - 1; i != 0; --i) {
            c = (unsigned char)src[i];
            trailing_bytes = UTF8_GetTrailingBytes(c);
            if (trailing_bytes) {
                if ((bytes - i) != (trailing_bytes + 1)) bytes = i;
                break;
            }
        }
    }
    SDL_memcpy(dst, src, bytes);
}
dst[bytes] = '\0';
```
The model returns `bytes`; the output is `src.take bytes` and a NUL. `s` is the source up to
its terminator, so `s.length = SDL_strlen(src)`. -/

def isLeadB (c : Byte) : Bool := 0xC0 ≤ c && c ≤ 0xF4
def isTrailB (c : Byte) : Bool := 0x80 ≤ c && c ≤ 0xBF
def trailingBytes (c : Byte) : Nat :=
  if 0xC0 ≤ c && c ≤ 0xDF then 1
  else if 0xE0 ≤ c && c ≤ 0xEF then 2
  else if 0xF0 ≤ c && c ≤ 0xF4 then 3
  else 0

/-- The C loop: `scanC s b i` runs the body for `i, i-1, …, 1` (the `i != 0` condition). -/
def scanC (s : Bytes) (b : Nat) : Nat → Nat
  | 0 => b
  | i + 1 =>
    if trailingBytes (byteAt s (i + 1)) ≠ 0 then
      (if b - (i + 1) ≠ trailingBytes (byteAt s (i + 1)) + 1 then i + 1 else b)
    else scanC s b i

/-- The fix: the same loop, also running the body for `i = 0`. -/
def scanFix (s : Bytes) (b : Nat) : Nat → Nat
  | 0 =>
    if trailingBytes (byteAt s 0) ≠ 0 then
      (if b ≠ trailingBytes (byteAt s 0) + 1 then 0 else b)
    else b
  | i + 1 =>
    if trailingBytes (byteAt s (i + 1)) ≠ 0 then
      (if b - (i + 1) ≠ trailingBytes (byteAt s (i + 1)) + 1 then i + 1 else b)
    else scanFix s b i

/-- Everything after `bytes` is computed, for `bytes ≥ 1`. -/
def lcpyCore (scan : Bytes → Nat → Nat → Nat) (s : Bytes) (b : Nat) : Nat :=
  if isLeadB (byteAt s (b - 1)) then b - 1
  else if isTrailB (byteAt s (b - 1)) then scan s b (b - 1)
  else b

def lcpyWith (scan : Bytes → Nat → Nat → Nat) (s : Bytes) (d : Nat) : Nat :=
  if d = 0 then 0
  else if min s.length (d - 1) = 0 then 0
  else lcpyCore scan s (min s.length (d - 1))

/-- `SDL_utf8strlcpy(dst, s, d)`: the number of bytes copied. -/
def cLcpy : Bytes → Nat → Nat := lcpyWith scanC
/-- The same with the scan extended to index 0. -/
def fixLcpy : Bytes → Nat → Nat := lcpyWith scanFix

/-- F-007, concretely: copying `"€"` (`E2 82 AC`) into a 3-byte buffer keeps `E2 82`, a
truncated sequence; the fix keeps nothing. -/
theorem lcpy_truncates_euro :
    cLcpy [0xE2, 0x82, 0xAC] 3 = 2 ∧ fixLcpy [0xE2, 0x82, 0xAC] 3 = 0 ∧
    (stepAt [0xE2, 0x82] 0 2).cp = invalid := by
  decide

theorem scanC_le (s : Bytes) (b : Nat) : ∀ i, i < b → scanC s b i ≤ b
  | 0, _ => by simp [scanC]
  | i + 1, h => by
    unfold scanC
    split
    · split <;> omega
    · exact scanC_le s b i (by omega)

/-- Memory safety on any input: the copy is at most `strlen(src)` bytes and, with the NUL, fits
in `dst_bytes`. (The C reads `src[i]` only for `i < bytes`, and `SDL_strlen`.) -/
theorem lcpy_bounds (s : Bytes) (d : Nat) :
    cLcpy s d ≤ s.length ∧ (0 < d → cLcpy s d + 1 ≤ d) := by
  unfold cLcpy lcpyWith lcpyCore
  by_cases hd : d = 0
  · simp [hd]
  · simp only [hd, if_false]
    split
    · omega
    · have := scanC_le s (min s.length (d - 1)) (min s.length (d - 1) - 1) (by omega)
      split
      · omega
      · split <;> omega

/-! #### Well-formed input -/

/-- What the scan sees in an encoded character. -/
theorem enc_lcpy_bytes (c : CP) :
    ((cEncode c).n = 1 → isLeadB (cEncode c).e0 = false ∧ isTrailB (cEncode c).e0 = false) ∧
    ((cEncode c).n ≥ 2 → isLeadB (cEncode c).e0 = true) ∧
    ((cEncode c).n ≥ 2 → isTrailB (cEncode c).e1 = true) ∧
    ((cEncode c).n ≥ 3 → isTrailB (cEncode c).e2 = true) ∧
    ((cEncode c).n ≥ 4 → isTrailB (cEncode c).e3 = true) ∧
    ((cEncode c).n = 2 → (0xC0 ≤ (cEncode c).e0 && (cEncode c).e0 ≤ 0xDF) = true) ∧
    ((cEncode c).n = 3 → (0xC0 ≤ (cEncode c).e0 && (cEncode c).e0 ≤ 0xDF) = false ∧
                          (0xE0 ≤ (cEncode c).e0 && (cEncode c).e0 ≤ 0xEF) = true) ∧
    ((cEncode c).n = 4 → (0xC0 ≤ (cEncode c).e0 && (cEncode c).e0 ≤ 0xDF) = false ∧
                          (0xE0 ≤ (cEncode c).e0 && (cEncode c).e0 ≤ 0xEF) = false ∧
                          (0xF0 ≤ (cEncode c).e0 && (cEncode c).e0 ≤ 0xF4) = true) := by
  generalize he : cEncode c = e
  simp only [cEncode, sanitize, mkE, bt, invalid] at he
  simp only [isLeadB, isTrailB, Enc.e0, Enc.e1, Enc.e2, Enc.e3, Enc.n]
  bv_decide

theorem trailingBytes_of_trail (x : Byte) (h : isTrailB x = true) : trailingBytes x = 0 := by
  simp only [isTrailB] at h
  have h1 : (0xC0 ≤ x && x ≤ 0xDF) = false := by bv_decide
  have h2 : (0xE0 ≤ x && x ≤ 0xEF) = false := by bv_decide
  have h3 : (0xF0 ≤ x && x ≤ 0xF4) = false := by bv_decide
  simp only [trailingBytes, h1, h2, h3, Bool.false_eq_true, ↓reduceIte]

theorem not_lead_of_trail (x : Byte) (h : isTrailB x = true) : isLeadB x = false := by
  simp only [isTrailB, isLeadB] at *; bv_decide

/-- Byte `t ≥ 1` of an encoded character is a trailing byte. -/
theorem encByte_trail (c : CP) (t : Nat) (h1 : 1 ≤ t) (h2 : t < (encL c).length) :
    isTrailB (encByte c t) = true := by
  obtain ⟨_, _, a1, a2, a3, _⟩ := enc_lcpy_bytes c
  have h4 := (encL_length_pos c).2
  rcases t with _ | _ | _ | _ | t
  · omega
  · exact a1 (n_ge_of_length c 2 (by decide) (by omega))
  · exact a2 (n_ge_of_length c 3 (by decide) (by omega))
  · exact a3 (n_ge_of_length c 4 (by decide) (by omega))
  · omega

theorem encByte_lead (c : CP) (h2 : 2 ≤ (encL c).length) :
    isLeadB (encByte c 0) = true ∧ trailingBytes (encByte c 0) = (encL c).length - 1 := by
  obtain ⟨_, l, _, _, _, t2, t3, t4⟩ := enc_lcpy_bytes c
  have lead := l (n_ge_of_length c 2 (by decide) h2)
  show isLeadB (cEncode c).e0 = true ∧ trailingBytes (cEncode c).e0 = (encL c).length - 1
  refine ⟨lead, ?_⟩
  rcases enc_cases c with h | h | h | h
  · have : (encL c).length = 1 := by simp [encL, h]
    omega
  · have : (encL c).length = 2 := by simp [encL, h]
    rw [this]; simp only [trailingBytes, t2 h, ↓reduceIte]
  · have : (encL c).length = 3 := by simp [encL, h]
    rw [this]; simp only [trailingBytes, (t3 h).1, (t3 h).2, Bool.false_eq_true, ↓reduceIte]
  · have : (encL c).length = 4 := by simp [encL, h]
    rw [this]
    simp only [trailingBytes, (t4 h).1, (t4 h).2.1, (t4 h).2.2, Bool.false_eq_true, ↓reduceIte]

theorem encByte_ascii (c : CP) (h1 : (encL c).length = 1) :
    isLeadB (encByte c 0) = false ∧ isTrailB (encByte c 0) = false := by
  obtain ⟨a, _⟩ := enc_lcpy_bytes c
  apply a
  rcases enc_cases c with h | h | h | h <;> simp [encL, h] at h1 ⊢

/-- The scan walks over bytes whose `trailingBytes` is 0 without stopping. -/
theorem scanC_skip (s : Bytes) (b m : Nat) :
    ∀ k, (∀ t, 1 ≤ t → t ≤ k → trailingBytes (byteAt s (m + t)) = 0) →
      scanC s b (m + k) = scanC s b m
  | 0, _ => rfl
  | k + 1, h => by
    have hz := h (k + 1) (by omega) (by omega)
    rw [show m + (k + 1) = (m + k) + 1 by omega] at hz ⊢
    rw [scanC, if_neg (by rw [hz]; simp)]
    exact scanC_skip s b m k (fun t a b => h t a (by omega))

theorem scanFix_skip (s : Bytes) (b m : Nat) :
    ∀ k, (∀ t, 1 ≤ t → t ≤ k → trailingBytes (byteAt s (m + t)) = 0) →
      scanFix s b (m + k) = scanFix s b m
  | 0, _ => rfl
  | k + 1, h => by
    have hz := h (k + 1) (by omega) (by omega)
    rw [show m + (k + 1) = (m + k) + 1 by omega] at hz ⊢
    rw [scanFix, if_neg (by rw [hz]; simp)]
    exact scanFix_skip s b m k (fun t a b => h t a (by omega))

theorem scanC_at (s : Bytes) (b m T : Nat) (hT : trailingBytes (byteAt s m) = T) (h0 : T ≠ 0) :
    scanC s b m = if m = 0 then b else (if b - m ≠ T + 1 then m else b) := by
  rcases m with _ | m
  · simp [scanC]
  · simp [scanC, hT, h0]

theorem scanFix_at (s : Bytes) (b m T : Nat) (hT : trailingBytes (byteAt s m) = T) (h0 : T ≠ 0) :
    scanFix s b m = if b - m ≠ T + 1 then m else b := by
  rcases m with _ | m
  · simp [scanFix, hT, h0]
  · simp [scanFix, hT, h0]

/-- One cut point: the copy limit `b` falls `j` bytes into the encoded character `c`, which sits
after `P`. The fix keeps `b` if `c` is complete (`j = n`), else cuts back to `c`'s start. The C
does the same, except when `c` starts at index 0 and `j ≥ 2`: its scan never looks at index 0,
so it keeps all `b` bytes. -/
theorem lcpy_local (P Q : Bytes) (c : CP) (j : Nat) (hj1 : 1 ≤ j) (hjn : j ≤ (encL c).length) :
    lcpyCore scanFix (P ++ encL c ++ Q) (P.length + j) =
      (if j = (encL c).length then P.length + j else P.length) ∧
    lcpyCore scanC (P ++ encL c ++ Q) (P.length + j) =
      (if j = (encL c).length ∨ (P.length = 0 ∧ 2 ≤ j) then P.length + j else P.length) := by
  have bat : ∀ t, t < (encL c).length →
      byteAt (P ++ encL c ++ Q) (P.length + t) = encByte c t := by
    intro t ht; rw [List.append_assoc, byteAt_append, byteAt_encL c Q t ht]
  have hn := encL_length_pos c
  unfold lcpyCore
  rw [show P.length + j - 1 = P.length + (j - 1) by omega, bat (j - 1) (by omega)]
  by_cases hj : j = 1
  · subst hj
    by_cases h1 : (encL c).length = 1
    · obtain ⟨a, b⟩ := encByte_ascii c h1
      simp [a, b, h1]
    · obtain ⟨l, _⟩ := encByte_lead c (by omega)
      simp [l]; omega
  · -- j ≥ 2: byte j-1 is a trailing byte, the scan walks back to the lead at P.length
    have ht := encByte_trail c (j - 1) (by omega) (by omega)
    obtain ⟨_, T⟩ := encByte_lead c (by omega)
    have skip : ∀ t, 1 ≤ t → t ≤ j - 1 →
        trailingBytes (byteAt (P ++ encL c ++ Q) (P.length + t)) = 0 := by
      intro t a b'
      rw [bat t (by omega)]
      exact trailingBytes_of_trail _ (encByte_trail c t a (by omega))
    have lead : trailingBytes (byteAt (P ++ encL c ++ Q) P.length) = (encL c).length - 1 := by
      have := bat 0 (by omega); simp only [Nat.add_zero] at this; rw [this, T]
    rw [not_lead_of_trail _ ht, ht]
    simp only [Bool.false_eq_true, if_false, if_true]
    constructor
    · rw [scanFix_skip _ _ _ _ skip, scanFix_at _ _ _ _ lead (by omega)]
      by_cases e : j = (encL c).length <;> simp [e] <;> omega
    · rw [scanC_skip _ _ _ _ skip, scanC_at _ _ _ _ lead (by omega)]
      by_cases e : j = (encL c).length <;> by_cases p : P.length = 0 <;> simp [e, p] <;> omega

/-- Every cut point `1 ≤ b ≤ |s|` of a well-formed string falls inside (or at the end of) one
character. -/
theorem encodeAll_cut (cs : List CP) (b : Nat) (h1 : 1 ≤ b) (h2 : b ≤ (encodeAll cs).length) :
    ∃ cs1 c cs2 j, cs = cs1 ++ c :: cs2 ∧ 1 ≤ j ∧ j ≤ (encL c).length ∧
      b = (encodeAll cs1).length + j := by
  induction cs generalizing b with
  | nil => simp [encodeAll] at h2; omega
  | cons c cs ih =>
    rw [encodeAll_cons, List.length_append] at h2
    by_cases hb : b ≤ (encL c).length
    · exact ⟨[], c, cs, b, by simp, h1, hb, by simp [encodeAll]⟩
    · obtain ⟨cs1, c', cs2, j, e, a, b', d⟩ := ih (b - (encL c).length) (by omega) (by omega)
      refine ⟨c :: cs1, c', cs2, j, by simp [e], a, b', ?_⟩
      rw [encodeAll_cons, List.length_append]; omega

theorem encodeAll_length_pos (c : CP) (cs : List CP) : 1 ≤ (encodeAll (c :: cs)).length := by
  rw [encodeAll_cons, List.length_append]; have := encL_length_pos c; omega

theorem encodeAll_nil : encodeAll [] = [] := rfl

theorem encodeAll_snoc_length (cs : List CP) (c : CP) :
    (encodeAll (cs ++ [c])).length = (encodeAll cs).length + (encL c).length := by
  rw [encodeAll_append, List.length_append, show encodeAll [c] = encL c by simp [encodeAll]]

theorem encodeAll_split_length (cs1 cs2 : List CP) (c : CP) :
    (encodeAll (cs1 ++ c :: cs2)).length =
      (encodeAll cs1).length + (encL c).length + (encodeAll cs2).length := by
  rw [encodeAll_append, encodeAll_cons, List.length_append, List.length_append]; omega

/-- **The fixed `utf8strlcpy` is exactly right** on well-formed input: it copies the longest
prefix of whole characters that fits in `dst_bytes - 1` bytes. -/
theorem fixLcpy_wf (cs : List CP) (d : Nat) (hd : 0 < d) :
    ∃ cs1 cs2, cs = cs1 ++ cs2 ∧ fixLcpy (encodeAll cs) d = (encodeAll cs1).length ∧
      (encodeAll cs1).length ≤ d - 1 ∧
      (∀ c cs2', cs2 = c :: cs2' → (encodeAll cs1).length + (encL c).length > d - 1) := by
  unfold fixLcpy lcpyWith
  have hd0 : d ≠ 0 := by omega
  by_cases hb : min (encodeAll cs).length (d - 1) = 0
  · simp only [hd0, hb, ↓reduceIte]
    refine ⟨[], cs, by simp, rfl, by simp [encodeAll_nil], ?_⟩
    intro c cs2' e; subst e
    have := encodeAll_length_pos c cs2'; have := encL_length_pos c
    simp only [encodeAll_nil, List.length_nil]; omega
  · simp only [hd0, hb, ↓reduceIte]
    obtain ⟨cs1, c, cs2, j, e, hj1, hjn, hbj⟩ :=
      encodeAll_cut cs (min (encodeAll cs).length (d - 1)) (by omega) (by omega)
    have hs : encodeAll cs = encodeAll cs1 ++ encL c ++ encodeAll cs2 := by
      rw [e, encodeAll_append, encodeAll_cons, List.append_assoc]
    have hlen := encodeAll_split_length cs1 cs2 c
    rw [← e] at hlen
    have L := (lcpy_local (encodeAll cs1) (encodeAll cs2) c j hj1 hjn).1
    rw [← hs, ← hbj] at L
    rw [L]
    by_cases hjn' : j = (encL c).length
    · rw [if_pos hjn']
      refine ⟨cs1 ++ [c], cs2, by simp [e], by rw [encodeAll_snoc_length]; omega,
              by rw [encodeAll_snoc_length]; omega, ?_⟩
      intro c' cs2' e2; subst e2
      have := encodeAll_length_pos c' cs2'; have := encL_length_pos c'
      rw [encodeAll_snoc_length]; omega
    · rw [if_neg hjn']
      refine ⟨cs1, c :: cs2, e, rfl, by omega, ?_⟩
      intro c' cs2' e2; injection e2 with e3; subst e3; omega

/-- **F-007, exactly.** On well-formed input the real `SDL_utf8strlcpy` differs from the fix
*if and only if* the copy limit `b = min(strlen, dst_bytes - 1)` falls inside the string's
first character, at least 2 bytes in. Then the C keeps those `b` bytes, a truncated sequence. -/
theorem lcpy_c_vs_fixed (cs : List CP) (d : Nat) (hd : 0 < d) :
    cLcpy (encodeAll cs) d ≠ fixLcpy (encodeAll cs) d ↔
      ∃ c cs', cs = c :: cs' ∧ 2 ≤ min (encodeAll cs).length (d - 1) ∧
        min (encodeAll cs).length (d - 1) < (encL c).length := by
  unfold cLcpy fixLcpy lcpyWith
  have hd0 : d ≠ 0 := by omega
  by_cases hb : min (encodeAll cs).length (d - 1) = 0
  · simp only [hd0, hb, ↓reduceIte, ne_eq, not_true_eq_false, false_iff, not_exists, not_and]
    intros; omega
  · simp only [hd0, hb, ↓reduceIte]
    obtain ⟨cs1, c, cs2, j, e, hj1, hjn, hbj⟩ :=
      encodeAll_cut cs (min (encodeAll cs).length (d - 1)) (by omega) (by omega)
    have hs : encodeAll cs = encodeAll cs1 ++ encL c ++ encodeAll cs2 := by
      rw [e, encodeAll_append, encodeAll_cons, List.append_assoc]
    have L := lcpy_local (encodeAll cs1) (encodeAll cs2) c j hj1 hjn
    rw [← hs, ← hbj] at L
    rw [L.1, L.2]
    constructor
    · intro hne
      have a : j ≠ (encL c).length := by
        intro a; apply hne; simp [a]
      have p : (encodeAll cs1).length = 0 ∧ 2 ≤ j := by
        by_cases p : (encodeAll cs1).length = 0 ∧ 2 ≤ j
        · exact p
        · exfalso; apply hne
          rw [if_neg (fun h => h.elim a p), if_neg a]
      have h0 : cs1 = [] := by
        rcases cs1 with _ | ⟨x, xs⟩
        · rfl
        · have := encodeAll_length_pos x xs; omega
      subst h0
      exact ⟨c, cs2, by simpa using e, by omega, by omega⟩
    · rintro ⟨c0, cs0, e0, h2, hlt⟩
      have h0 : cs1 = [] := by
        rcases cs1 with _ | ⟨x, xs⟩
        · rfl
        · exfalso
          rw [e] at e0; simp only [List.cons_append, List.cons.injEq] at e0
          obtain ⟨rfl, -⟩ := e0
          rw [encodeAll_cons, List.length_append] at hbj; omega
      subst h0
      rw [e] at e0; simp only [List.nil_append, List.cons.injEq] at e0
      obtain ⟨rfl, -⟩ := e0
      have : j ≠ (encL c).length := by
        simp only [encodeAll_nil, List.length_nil, Nat.zero_add] at hbj; omega
      simp only [encodeAll_nil, List.length_nil] at hbj ⊢
      rw [if_neg this, if_pos (by simp <;> omega)]
      intro h; omega

end SDLVerif.Utf8
