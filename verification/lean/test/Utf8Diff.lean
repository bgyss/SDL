import SDLVerif.Utf8
open SDLVerif.Utf8

/-! Prints `cStep` on a fixed input grid, one line per case, in the same format as
`test/utf8_diff.c` prints the real `SDL_StepUTF8`. `test/utf8_diff.sh` diffs the two.

The grid is every lead byte, times "interesting" values for the continuation bytes (every
range boundary RFC 3629 or the C cares about), times lengths 0..5. -/

def interesting : List Nat :=
  [0x00, 0x01, 0x3F, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xFF]

def main : IO Unit := do
  let out ← IO.getStdout
  for b0 in List.range 256 do
    for b1 in interesting do
      for b2 in interesting do
        for b3 in interesting do
          let step (slen : Nat) :=
            cStep (BitVec.ofNat 8 b0) (BitVec.ofNat 8 b1) (BitVec.ofNat 8 b2)
                  (BitVec.ofNat 8 b3) (BitVec.ofNat 64 slen)
          for slen in List.range 6 do
            let r := step slen
            out.putStrLn s!"{b0} {b1} {b2} {b3} {slen} {r.cp.toNat} {r.adv.toNat}"
          -- SDL_StepUTF8(&p, NULL) is StepUTF8(&p, 4) (SDL_string.c:262)
          let r := step 4
          out.putStrLn s!"{b0} {b1} {b2} {b3} N {r.cp.toNat} {r.adv.toNat}"
