import SDLVerif.Rect
import SDLVerif.RectLine
open SDLVerif.Rect

/-! Reads the lines test/rect_diff.c prints, recomputes everything after " | " from the inputs
with the Lean models of the fixed code (`fixed := true`, `RectLine.clip`), and prints each line
in the same format. test/rect_diff.sh diffs the C's output against this program's. -/

def i32 (n : Int) : I32 := BitVec.ofInt 32 n
def show32 (v : I32) : String := toString v.toInt
def showR (r : R) : String := s!"{show32 r.x} {show32 r.y} {show32 r.w} {show32 r.h}"
def bit (b : Bool) : String := if b then "1" else "0"

def rectOf (v : List Int) : R := ⟨i32 v[0]!, i32 v[1]!, i32 v[2]!, i32 v[3]!⟩

partial def pairs : List Int → List (I32 × I32)
  | x :: y :: rest => (i32 x, i32 y) :: pairs rest
  | _ => []

def compute (kind : String) (v : List Int) : String :=
  match kind with
  | "R" =>
    let a := rectOf v
    let b := rectOf (v.drop 4)
    let h := (hasInter true a b).1
    let i := inter true a b
    let u := union true a b
    let us := if u.ok then s!"1 {showR u.r}" else "0"
    s!"{bit h} {bit i.ok} {showR i.r} {us}"
  | "E" =>
    let n := v[0]!.toNat
    let c := if v[1]! = 1 then some (rectOf (v.drop 2)) else none
    let pts := (pairs (v.drop 6)).take n
    let o := enclose true pts c
    if o.ok then s!"1 {showR o.r}" else "0"
  | "L" =>
    let (ok, x1, y1, x2, y2) :=
      SDLVerif.RectLine.clip v[0]! v[1]! v[2]! v[3]! v[4]! v[5]! v[6]! v[7]!
    s!"{bit ok} {x1} {y1} {x2} {y2}"
  | _ => "?"

partial def loop (inp : IO.FS.Stream) (out : IO.FS.Stream) : IO Unit := do
  let line ← inp.getLine
  if line.isEmpty then return
  let line := String.ofList (line.toList.filter fun ch => ch != '\n' && ch != '\r')
  match String.splitOn line " | " with
  | [lhs, _] =>
    match String.splitOn lhs " " with
    | kind :: nums =>
      let v := nums.filterMap String.toInt?
      out.putStrLn s!"{lhs} | {compute kind v}"
    | [] => out.putStrLn "?"
  | _ => out.putStrLn "?"
  loop inp out

def main : IO Unit := do
  loop (← IO.getStdin) (← IO.getStdout)
