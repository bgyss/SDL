import SDLVerif.Utf8

/-
UTF-8 encoding in SDL: `SDL_UCS4ToUTF8` (src/stdlib/SDL_string.c:47-80, commit cb6224d2e;
contract in include/SDL3/SDL_stdinc.h:4280-4307).

* `cEncode` transcribes the C with C widths: the code point is `BitVec 32`, each output byte
  `(Uint8)` is a truncation to `BitVec 8`.
* The encoder writes 1–4 bytes and leaves the rest of the 4-byte buffer alone. The theorems put
  arbitrary bytes (`x1 x2 x3`) in the unwritten positions, so they hold whatever the caller's
  buffer contained.
* The round trips are checked against both the RFC 3629 grammar (`wfLen`/`decodeVal`, written
  independently of SDL) and SDL's own decoder (`cStep`), over all 2^32 code points.
-/
namespace SDLVerif.Utf8

/-- Lines 51-55: values above U+10FFFF and UTF-16 surrogates become U+FFFD. -/
def sanitize (c : CP) : CP :=
  if c > 0x10FFFF then invalid
  else if 0xD800 ≤ c && c ≤ 0xDFFF then invalid
  else c

/-- `(Uint8)` cast. -/
def bt (c : CP) : Byte := c.setWidth 8

/-- Encoder result, packed as `e0 ++ e1 ++ e2 ++ e3 ++ n` (bytes written, then the count).
Bytes at positions `≥ n` are not written by the C; they are 0 here and never used. -/
abbrev Enc := BitVec 40

def mkE (e0 e1 e2 e3 n : Byte) : Enc := e0 ++ e1 ++ e2 ++ e3 ++ n
def Enc.e0 (e : Enc) : Byte := e.extractLsb' 32 8
def Enc.e1 (e : Enc) : Byte := e.extractLsb' 24 8
def Enc.e2 (e : Enc) : Byte := e.extractLsb' 16 8
def Enc.e3 (e : Enc) : Byte := e.extractLsb' 8 8
def Enc.n (e : Enc) : Byte := e.extractLsb' 0 8

/-- Transcription of `SDL_UCS4ToUTF8(codepoint, dst)` for non-NULL `dst`. -/
def cEncode (c0 : CP) : Enc :=
  let c := sanitize c0
  if c ≤ 0x7F then mkE (bt c) 0 0 0 1
  else if c ≤ 0x7FF then
    mkE (0xC0 ||| bt ((c >>> 6) &&& 0x1F)) (0x80 ||| bt (c &&& 0x3F)) 0 0 2
  else if c ≤ 0xFFFF then
    mkE (0xE0 ||| bt ((c >>> 12) &&& 0x0F)) (0x80 ||| bt ((c >>> 6) &&& 0x3F))
        (0x80 ||| bt (c &&& 0x3F)) 0 3
  else
    mkE (0xF0 ||| bt ((c >>> 18) &&& 0x07)) (0x80 ||| bt ((c >>> 12) &&& 0x3F))
        (0x80 ||| bt ((c >>> 6) &&& 0x3F)) (0x80 ||| bt (c &&& 0x3F)) 4

/-- A Unicode scalar value other than NUL: the code points a C string can carry. -/
def scalar (c : CP) : Bool := c != 0 && c ≤ 0x10FFFF && !(0xD800 ≤ c && c ≤ 0xDFFF)

/-- The 4 bytes in memory after encoding: written bytes, then whatever was there (`x1 x2 x3`). -/
def mem1 (e : Enc) (x1 : Byte) : Byte := if e.n ≥ 2 then e.e1 else x1
def mem2 (e : Enc) (x2 : Byte) : Byte := if e.n ≥ 3 then e.e2 else x2
def mem3 (e : Enc) (x3 : Byte) : Byte := if e.n ≥ 4 then e.e3 else x3

/-- The encoder writes between 1 and 4 bytes, so a 4-byte buffer is always enough (header). -/
theorem enc_len (c : CP) : 1 ≤ (cEncode c).n ∧ (cEncode c).n ≤ 4 := by
  simp only [cEncode, sanitize, mkE, Enc.n, bt, invalid]
  bv_decide

/-- The encoder is correct against RFC 3629 itself: for every scalar value, the bytes written
are one well-formed character of exactly that length, and they encode that value. -/
theorem enc_wf (c : CP) (x1 x2 x3 : Byte) : scalar c →
    let e := cEncode c
    wfLen e.e0 (mem1 e x1) (mem2 e x2) (mem3 e x3) = e.n ∧
    decodeVal e.n e.e0 (mem1 e x1) (mem2 e x2) (mem3 e x3) = c := by
  simp only [scalar, cEncode, sanitize, mkE, Enc.e0, Enc.e1, Enc.e2, Enc.e3, Enc.n, mem1, mem2, mem3, bt, invalid, wfLen, decodeVal, tail, inR, w]
  bv_decide

set_option maxHeartbeats 0 in
/-- Encode, then decode with SDL's own `StepUTF8`: every scalar value comes back, and the decoder
consumes exactly the bytes the encoder wrote, for any slen that covers them. -/
theorem enc_dec_roundtrip (c : CP) (x1 x2 x3 : Byte) (slen : Size) : scalar c →
    (cEncode c).n.setWidth 64 ≤ slen →
    let e := cEncode c
    (cStep e.e0 (mem1 e x1) (mem2 e x2) (mem3 e x3) slen).cp = c ∧
    (cStep e.e0 (mem1 e x1) (mem2 e x2) (mem3 e x3) slen).adv = e.n := by
  -- Name the encoder output and the decoder result, so that unfolding `cStep` copies atoms
  -- rather than the whole encoder term into each use of its `let`s.
  intro hsc hn
  simp only []
  generalize he : cEncode c = e at *
  generalize hb1 : mem1 e x1 = b1
  generalize hb2 : mem2 e x2 = b2
  generalize hb3 : mem3 e x3 = b3
  generalize hr : cStep e.e0 b1 b2 b3 slen = r
  simp only [cEncode, sanitize, mkE, bt, invalid] at he
  simp only [cStep, mk, isCont, w] at hr
  simp only [mem1, mem2, mem3] at hb1 hb2 hb3
  simp only [scalar, Res.cp, Res.adv, Enc.e0, Enc.e1, Enc.e2, Enc.e3, Enc.n] at *
  bv_decide

/-- Header: "If `codepoint` is an invalid value (outside the Unicode range, or a UTF-16 surrogate
value, etc), this will use U+FFFD". The output is then `EF BF BD`. -/
theorem enc_invalid (c : CP) : (c > 0x10FFFF ∨ (0xD800 ≤ c ∧ c ≤ 0xDFFF)) →
    (cEncode c).e0 = 0xEF ∧ (cEncode c).e1 = 0xBF ∧ (cEncode c).e2 = 0xBD ∧ (cEncode c).n = 3 := by
  simp only [cEncode, sanitize, mkE, Enc.e0, Enc.e1, Enc.e2, Enc.n, bt, invalid]
  bv_decide

/-- NUL encodes as the single byte 0, which the decoder reads as end of string. This is the one
scalar value that does not round-trip, by design of C strings. -/
theorem enc_nul : (cEncode 0).e0 = 0 ∧ (cEncode 0).n = 1 := by
  simp only [cEncode, sanitize, mkE, Enc.e0, Enc.n, bt, invalid]
  bv_decide

set_option maxHeartbeats 0 in
/-- Decode, then encode (UTF-8 is canonical): whenever `StepUTF8` returns an in-range character,
re-encoding it gives back exactly the bytes it consumed. So the decoder accepts no alternative
(overlong) spelling of any character. -/
theorem dec_enc_roundtrip (b0 b1 b2 b3 : Byte) (slen : Size) :
    let r := cStep b0 b1 b2 b3 slen
    r.cp ≠ 0 → r.cp ≠ invalid → r.cp ≤ 0x10FFFF →
      (cEncode r.cp).n = r.adv ∧ (cEncode r.cp).e0 = b0 ∧
      (r.adv ≥ 2 → (cEncode r.cp).e1 = b1) ∧ (r.adv ≥ 3 → (cEncode r.cp).e2 = b2) ∧
      (r.adv ≥ 4 → (cEncode r.cp).e3 = b3) := by
  simp only []
  generalize hr : cStep b0 b1 b2 b3 slen = r
  generalize he : cEncode r.cp = e
  simp only [cStep, mk, isCont, w] at hr
  simp only [cEncode, sanitize, mkE, bt, invalid] at he
  simp only [Res.cp, Res.adv, Enc.e0, Enc.e1, Enc.e2, Enc.e3, Enc.n, invalid] at *
  bv_decide

/-- The same for the fixed decoder (F-004/F-005 fix), with no range side condition. -/
theorem fixed_dec_enc_roundtrip (b0 b1 b2 b3 : Byte) (slen : Size) :
    let r := cFixed b0 b1 b2 b3 slen
    r.cp ≠ 0 → r.cp ≠ invalid →
      (cEncode r.cp).n = r.adv ∧ (cEncode r.cp).e0 = b0 ∧
      (r.adv ≥ 2 → (cEncode r.cp).e1 = b1) ∧ (r.adv ≥ 3 → (cEncode r.cp).e2 = b2) ∧
      (r.adv ≥ 4 → (cEncode r.cp).e3 = b3) := by
  simp only [cFixed, mk, Res.cp, Res.adv, isCont, w, cEncode, sanitize, mkE, Enc.e0, Enc.e1, Enc.e2, Enc.e3, Enc.n, bt, invalid]
  bv_decide

end SDLVerif.Utf8
