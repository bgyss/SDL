import SDLVerif.Utf8Fixed
open SDLVerif.Utf8

/-! Corpus differential test for the string-level models (Utf8String.lean). Reads one hex
string per line on stdin, and for each prints, in the same format as test/utf8_corpus.c prints
the real SDL functions:
* `F` the forward decode (`SDL_StepUTF8` with a length), code point and offset per step
* `B` the backward decode (`SDL_StepBackUTF8` from the end), code point and offset per step
* `L` `SDL_utf8strlcpy` byte counts for every `dst_bytes` from 1 to len + 2
The strings come from the fuzz_utf8 corpus (test/utf8_corpus.sh), cut at the first NUL. -/

def hexVal (c : Char) : Nat :=
  if '0' ≤ c ∧ c ≤ '9' then c.toNat - '0'.toNat
  else if 'a' ≤ c ∧ c ≤ 'f' then c.toNat - 'a'.toNat + 10
  else c.toNat - 'A'.toNat + 10

def parseHex : List Char → List Byte
  | a :: b :: rest => BitVec.ofNat 8 (hexVal a * 16 + hexVal b) :: parseHex rest
  | _ => []

/-- Forward steps with offsets (fuel = length + 1 is enough: each step advances). -/
def fwdSteps (s : Bytes) : Nat → Nat → List (Nat × Nat)
  | 0, _ => []
  | fuel + 1, i =>
    let r := stepAtF s i (s.length - i)
    if r.cp = 0 then [] else (r.cp.toNat, i) :: fwdSteps s fuel (i + r.adv.toNat)

def backSteps (s : Bytes) : Nat → Nat → List (Nat × Nat)
  | 0, _ => []
  | fuel + 1, p =>
    let r := cStepBackFix s p
    if r.1 = 0 then [] else (r.1.toNat, r.2) :: backSteps s fuel r.2

def showSteps (l : List (Nat × Nat)) : String :=
  String.join (l.map fun (c, i) => s!" {c}@{i}")

partial def loop (h : IO.FS.Stream) (out : IO.FS.Stream) : IO Unit := do
  let line ← h.getLine
  if line.isEmpty then return
  let s := parseHex ((line.toList.filter fun ch => ch != '\n' && ch != '\r'))
  let n := s.length
  out.putStrLn s!"F{showSteps (fwdSteps s (n + 1) 0)}"
  out.putStrLn s!"B{showSteps (backSteps s (n + 1) n)}"
  out.putStrLn s!"L{String.join ((List.range (n + 2)).map fun d => s!" {fixLcpy s (d + 1)}")}"
  loop h out

def main : IO Unit := do
  loop (← IO.getStdin) (← IO.getStdout)
