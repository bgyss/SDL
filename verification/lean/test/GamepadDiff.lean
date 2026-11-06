import SDLVerif.GamepadMapping
open SDLVerif.Gamepad

/-! Reads the lines test/gamepad_diff.c prints ("<stored mapping> | <bindings>"), recomputes the
bindings from the stored mapping with the Lean model, and prints each line in the same format.
test/gamepad_diff.sh diffs the C's output against this program's.

The stored mapping is "<guid>,<name>,<body>"; SDL parses the body, and looks for the face-label
hints in it. -/

def showIn : Input → String
  | .axis a lo hi => s!"a{a},{lo},{hi}"
  | .button b => s!"b{b}"
  | .hat h m => s!"h{h}.{m}"

def showOut : Output → String
  | .axis a lo hi => s!"a{a},{lo},{hi}"
  | .button b => s!"b{b}"

def showBinds (bs : List Binding) : String :=
  String.join (bs.map fun b => s!" {showIn b.input}>{showOut b.output}")

/-- Everything after the second comma. -/
def bodyOf (s : List Char) : List Char :=
  match s.dropWhile (· ≠ ',') with
  | _ :: rest => match rest.dropWhile (· ≠ ',') with
    | _ :: body => body
    | [] => []
  | [] => []

partial def loop (inp : IO.FS.Stream) (out : IO.FS.Stream) : IO Unit := do
  let line ← inp.getLine
  if line.isEmpty then return
  let line := String.ofList (line.toList.filter fun ch => ch != '\n' && ch != '\r')
  match String.splitOn line " |" with
  | [stored, _] =>
    let body := bodyOf stored.toList
    let (bs, _) := parseConfig body (axbyOf body) (baxyOf body)
    out.putStrLn s!"{stored} |{showBinds bs}"
  | _ => out.putStrLn "?"
  loop inp out

def main : IO Unit := do
  loop (← IO.getStdin) (← IO.getStdout)
