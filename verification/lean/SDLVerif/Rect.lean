import Std.Tactic.BVDecide

/-
The integer rect functions of SDL (src/video/SDL_rect_impl.h, instantiated for `SDL_Rect` in
src/video/SDL_rect.c: SCALARTYPE = int, BIGSCALARTYPE = Sint64, ENCLOSEPOINTS_EPSILON = 1).

Method (PLAN.md, Phase 5):
* Each function is transcribed with the C types: `int` is `BitVec 32` with two's-complement
  wrap-around, `Sint64` is `BitVec 64`. Every `int` addition or subtraction also reports whether
  it overflowed (`BitVec.saddOverflow` / `ssubOverflow`), and the results carry an `ub` flag
  that is the OR of all of them. Signed overflow is undefined behavior in C, so `ub = false` is
  the property that the code never executes UB.
* `fixed := true` is the code in this fork since cce7d368b (F-012, F-014, F-015). `fixed :=
  false` is the pre-fix code (cb6224d2e), which is kept as the record of the findings.
* `bv_decide` checks the theorems over all inputs (8 × 32 bits for two rects).
* test/rect_diff.sh ties the model to the real C on a boundary grid.
-/
namespace SDLVerif.Rect

abbrev I32 := BitVec 32
abbrev I64 := BitVec 64

structure R where
  x : I32
  y : I32
  w : I32
  h : I32
deriving DecidableEq, Repr

def INT_MIN : I32 := 0x80000000
def INT_MAX : I32 := 0x7FFFFFFF
/-- `SDL_MIN_SINT32 / 2` and `SDL_MAX_SINT32 / 2` (C division truncates toward zero). -/
def HALF_MIN : I32 := (-1073741824 : Int) |> BitVec.ofInt 32
def HALF_MAX : I32 := 1073741823

def wide (a : I32) : I64 := a.signExtend 64

/-- `SDL_RectEmpty`: `!r || r->w <= 0 || r->h <= 0` (r is never NULL here). -/
abbrev empty (r : R) : Bool := r.w.sle 0 || r.h.sle 0

/-- `SDL_RECT_CAN_OVERFLOW`. The fix added the two lower bounds on the size (F-015). -/
def canOverflow (fixed : Bool) (r : R) : Bool :=
  r.x.sle HALF_MIN || HALF_MAX.sle r.x ||
  r.y.sle HALF_MIN || HALF_MAX.sle r.y ||
  HALF_MAX.sle r.w || HALF_MAX.sle r.h ||
  (fixed && (r.w.sle HALF_MIN || r.h.sle HALF_MIN))

/-! ## `SDL_HasRectIntersection` -/

/-- One axis of `SDL_HasRectIntersection`: `Amin = a; Amax = Amin + aw; ...` then
`(Amax - 1) < Amin` means "no overlap". Returns (overlaps, ub). -/
def hasAxis (a aw b bw : I32) : Bool × Bool :=
  let ub0 := a.saddOverflow aw || b.saddOverflow bw
  let amin := a
  let amax := a + aw
  let bmin := b
  let bmax := b + bw
  let amin := if amin.slt bmin then bmin else amin   -- if (Bmin > Amin) Amin = Bmin
  let amax := if bmax.slt amax then bmax else amax   -- if (Bmax < Amax) Amax = Bmax
  (!(amax - 1).slt amin, ub0 || amax.ssubOverflow 1)

/-- `SDL_HasRectIntersection(A, B)`: returns (result, ub). The vertical axis is only computed
if the horizontal one overlaps. -/
def hasInter (fixed : Bool) (A B : R) : Bool × Bool :=
  if canOverflow fixed A || canOverflow fixed B then (false, false) else
  let hx := hasAxis A.x A.w B.x B.w
  if !hx.1 then (false, hx.2) else
  let hy := hasAxis A.y A.h B.y B.h
  (hy.1, hx.2 || hy.2)

/-! ## `SDL_GetRectIntersection` -/

/-- One axis: returns (result origin, result size, ub). The fixed code computes the size as
`(int)SDL_max((Sint64)Amax - Amin, (Sint64)INT_MIN)`; the old one as `Amax - Amin` in `int`. -/
def interAxis (fixed : Bool) (a aw b bw : I32) : I32 × I32 × Bool :=
  let ub0 := a.saddOverflow aw || b.saddOverflow bw
  let amin := if a.slt b then b else a
  let amax := if (b + bw).slt (a + aw) then b + bw else a + aw
  if fixed then
    let d : I64 := wide amax - wide amin
    let d := if d.slt (wide INT_MIN) then wide INT_MIN else d
    (amin, d.setWidth 32, ub0)
  else
    (amin, amax - amin, ub0 || amax.ssubOverflow amin)

structure Out where
  ok : Bool
  r : R
  ub : Bool

/-- `SDL_GetRectIntersection(A, B, &result)`. When the guard rejects the inputs, `result` is
not written; the model reports a zero rect then. -/
def inter (fixed : Bool) (A B : R) : Out :=
  if canOverflow fixed A || canOverflow fixed B then ⟨false, ⟨0, 0, 0, 0⟩, false⟩ else
  let ax := interAxis fixed A.x A.w B.x B.w
  let ay := interAxis fixed A.y A.h B.y B.h
  let r : R := ⟨ax.1, ay.1, ax.2.1, ay.2.1⟩
  ⟨!empty r, r, ax.2.2 || ay.2.2⟩

/-! ## `SDL_GetRectUnion` -/

/-- One axis of the union of two non-empty rects: (origin, size, overflow-error, ub). The fixed
code returns an error when `(Sint64)Amax - Amin > INT_MAX` (F-015). -/
def unionAxis (fixed : Bool) (a aw b bw : I32) : I32 × I32 × Bool × Bool :=
  let ub0 := a.saddOverflow aw || b.saddOverflow bw
  let amin := if b.slt a then b else a
  let amax := if (a + aw).slt (b + bw) then b + bw else a + aw
  if fixed && (wide INT_MAX).slt (wide amax - wide amin) then (amin, 0, true, ub0)
  else (amin, amax - amin, false, ub0 || amax.ssubOverflow amin)

def union (fixed : Bool) (A B : R) : Out :=
  if canOverflow fixed A || canOverflow fixed B then ⟨false, ⟨0, 0, 0, 0⟩, false⟩
  else if empty A then (if empty B then ⟨true, ⟨0, 0, 0, 0⟩, false⟩ else ⟨true, B, false⟩)
  else if empty B then ⟨true, A, false⟩
  else
    -- On an overflow error the C has already written some fields of *result; callers must not
    -- use it, and the model reports a zero rect.
    let ax := unionAxis fixed A.x A.w B.x B.w   -- (origin, size, error, ub)
    if ax.2.2.1 then ⟨false, ⟨0, 0, 0, 0⟩, ax.2.2.2⟩ else
    let ay := unionAxis fixed A.y A.h B.y B.h
    if ay.2.2.1 then ⟨false, ⟨0, 0, 0, 0⟩, ax.2.2.2 || ay.2.2.2⟩ else
    ⟨true, ⟨ax.1, ay.1, ax.2.1, ay.2.1⟩, ax.2.2.2 || ay.2.2.2⟩

/-! ## Specification -/

/-- The point `(px, py)` lies in `r`, computed exactly (in 64 bits, so the spec itself cannot
overflow): `x ≤ px < x + w` and `y ≤ py < y + h`. -/
def mem (r : R) (px py : I32) : Bool :=
  (wide r.x).sle (wide px) && (wide px).slt (wide r.x + wide r.w) &&
  (wide r.y).sle (wide py) && (wide py).slt (wide r.y + wide r.h)

/-- `inner` is inside `outer`, as exact integer intervals. -/
def sub (inner outer : R) : Bool :=
  (wide outer.x).sle (wide inner.x) && (wide inner.x + wide inner.w).sle (wide outer.x + wide outer.w) &&
  (wide outer.y).sle (wide inner.y) && (wide inner.y + wide inner.h).sle (wide outer.y + wide outer.h)

/-- Signed max/min on 64 bits, for stating the spec. -/
def max' (a b : I64) : I64 := if a.slt b then b else a
def min' (a b : I64) : I64 := if a.slt b then a else b

/-- Two results agree in every observable field. -/
def same (o p : Out) : Bool :=
  o.ok == p.ok && o.r.x == p.r.x && o.r.y == p.r.y && o.r.w == p.r.w && o.r.h == p.r.h

/-- Both inputs pass the fixed guard. -/
def guarded (A B : R) : Prop := canOverflow true A = false ∧ canOverflow true B = false

/-- Unfold every definition of this file, push projections into the branches, and hand the
goal to `bv_decide`. -/
macro "rect_decide" : tactic => `(tactic| (
  simp only [hasInter, hasAxis, inter, interAxis, union, unionAxis, canOverflow, empty, mem, sub,
    guarded, same, max', min', HALF_MIN, HALF_MAX, wide, INT_MIN, INT_MAX, apply_ite Prod.snd, apply_ite Prod.fst,
    apply_ite Out.ub, apply_ite Out.ok, apply_ite Out.r, apply_ite R.x, apply_ite R.y, apply_ite R.w,
    apply_ite R.h, Bool.cond_eq_ite, ite_true, ite_false, Bool.true_and, Bool.false_and, Bool.true_or,
    Bool.false_or]
    at *
  bv_decide))

/-! ## The fixed code never executes signed overflow (F-012, F-015) -/

theorem has_no_ub (A B : R) : (hasInter true A B).2 = false := by
  cases A; cases B; rect_decide

theorem inter_no_ub (A B : R) : (inter true A B).ub = false := by
  cases A; cases B; rect_decide

theorem union_no_ub (A B : R) : (union true A B).ub = false := by
  cases A; cases B; rect_decide

/-! ## The pre-fix code: where it overflowed (the record of F-015)

`SDL_HasRectIntersection` and `SDL_GetRectUnion`'s *guard* failures in the old code came only
from negative sizes and wide unions; `SDL_GetRectIntersection` could overflow even on inputs the
fixed guard accepts, which is why the fix computes its size in 64 bits. -/

/-- Pre-fix `SDL_HasRectIntersection` overflowed only on inputs the fixed guard now rejects. -/
theorem has_prefix_ub_only_unguarded (A B : R) :
    (hasInter false A B).2 = true → canOverflow true A = true ∨ canOverflow true B = true := by
  cases A; cases B; intro h; rect_decide

/-- Concrete pre-fix overflow: `A = {-1, 0, INT_MIN, 1}` computes `-1 + INT_MIN`. -/
theorem has_prefix_ub_example :
    (hasInter false ⟨-1, 0, INT_MIN, 1⟩ ⟨0, 0, 10, 10⟩).2 = true := by
  simp only [INT_MIN]; rect_decide

/-- Pre-fix `SDL_GetRectIntersection` could overflow on two rects that both pass the *fixed*
guard: a size near `-2^30` puts `Amax` far below `Amin`, and `Amax - Amin` leaves `int`. -/
theorem inter_prefix_ub_under_fixed_guard :
    canOverflow true ⟨1073741822, 0, -1073741823, 1⟩ = false ∧
    canOverflow true ⟨-1073741823, 0, -1073741823, 1⟩ = false ∧
    (inter false ⟨1073741822, 0, -1073741823, 1⟩ ⟨-1073741823, 0, -1073741823, 1⟩).ub = true := by
  rect_decide

/-- Concrete pre-fix overflow in `SDL_GetRectUnion`: two valid rects ~3·2^30 apart. -/
theorem union_prefix_ub_example :
    (union false ⟨-1073741800, 0, 10, 10⟩ ⟨1073741800, 0, 1073741800, 10⟩).ub = true := by
  rect_decide

/-- Patch audit: wherever the old code was defined (no UB) and the fixed guard accepts the
inputs, the fixed `SDL_GetRectIntersection` returns exactly what the old one did. -/
theorem inter_fix_audit (A B : R) (hg : guarded A B) (hub : (inter false A B).ub = false) :
    same (inter true A B) (inter false A B) = true := by
  cases A; cases B; rect_decide

/-- Patch audit for `SDL_GetRectUnion`: where the old code was defined and the fixed guard
accepts, the results agree. -/
theorem union_fix_audit (A B : R) (hg : guarded A B) (hub : (union false A B).ub = false) :
    same (union true A B) (union false A B) = true := by
  cases A; cases B; rect_decide

/-! ## What the fixed functions compute -/

theorem interAxis_fst_comm (a aw b bw : I32) :
    (interAxis true a aw b bw).1 = (interAxis true b bw a aw).1 := by
  simp only [interAxis, wide, INT_MIN, ite_true]; bv_decide

theorem interAxis_snd_comm (a aw b bw : I32) :
    (interAxis true a aw b bw).2.1 = (interAxis true b bw a aw).2.1 := by
  simp only [interAxis, wide, INT_MIN, ite_true, apply_ite Prod.snd, apply_ite Prod.fst]; bv_decide

/-- `SDL_GetRectIntersection` is symmetric. -/
theorem inter_comm (A B : R) : same (inter true A B) (inter true B A) = true := by
  obtain ⟨ax, ay, aw, ah⟩ := A
  obtain ⟨bx, by', bw, bh⟩ := B
  simp only [inter, same]
  rw [interAxis_fst_comm ax aw bx bw, interAxis_snd_comm ax aw bx bw,
    interAxis_fst_comm ay ah by' bh, interAxis_snd_comm ay ah by' bh, Bool.or_comm]
  split <;> simp

/-- Soundness: every point of the computed intersection lies in both inputs. -/
theorem inter_sound (A B : R) (px py : I32) :
    (inter true A B).ok = true → mem (inter true A B).r px py = true →
      mem A px py = true ∧ mem B px py = true := by
  cases A; cases B; intro h1 h2; rect_decide

/-- Completeness: on guarded inputs, every point in both inputs lies in the computed
intersection, which is then reported non-empty. -/
theorem inter_complete (A B : R) (px py : I32) (hg : guarded A B) :
    mem A px py = true → mem B px py = true →
      (inter true A B).ok = true ∧ mem (inter true A B).r px py = true := by
  cases A; cases B; intro h1 h2; rect_decide

/-- On guarded inputs, `SDL_HasRectIntersection` agrees with `SDL_GetRectIntersection`. -/
theorem has_iff_inter (A B : R) (hg : guarded A B) :
    (hasInter true A B).1 = (inter true A B).ok := by
  cases A; cases B; rect_decide

/-- `SDL_GetRectUnion` contains each non-empty input. -/
theorem union_contains (A B : R) :
    (union true A B).ok = true →
      (empty A = false → sub A (union true A B).r = true) ∧
      (empty B = false → sub B (union true A B).r = true) := by
  cases A; cases B; intro h; rect_decide

/-- ...and is the smallest such rect: its edges are edges of the inputs. -/
theorem union_tight (A B : R) (ha : empty A = false) (hb : empty B = false) :
    (union true A B).ok = true →
      ((union true A B).r.x = A.x ∨ (union true A B).r.x = B.x) ∧
      ((union true A B).r.y = A.y ∨ (union true A B).r.y = B.y) ∧
      ((union true A B).r.x + (union true A B).r.w = A.x + A.w ∨
        (union true A B).r.x + (union true A B).r.w = B.x + B.w) ∧
      ((union true A B).r.y + (union true A B).r.h = A.y + A.h ∨
        (union true A B).r.y + (union true A B).r.h = B.y + B.h) := by
  cases A; cases B; intro h; rect_decide

/-- On guarded non-empty inputs, `SDL_GetRectUnion` fails exactly when the union does not fit
in an `int` (its width or height would exceed `INT_MAX`). -/
theorem union_fails_iff_too_wide (A B : R) (hg : guarded A B)
    (ha : empty A = false) (hb : empty B = false) :
    (union true A B).ok = false ↔
      ((wide INT_MAX).slt (max' (wide A.x + wide A.w) (wide B.x + wide B.w) - min' (wide A.x) (wide B.x)) ∨
       (wide INT_MAX).slt (max' (wide A.y + wide A.h) (wide B.y + wide B.h) - min' (wide A.y) (wide B.y))) := by
  cases A; cases B
  constructor <;> intro h <;> rect_decide

/-! ## `SDL_GetRectEnclosingPoints`

The C loops over the points keeping `minx/maxx/miny/maxy`; with a clip rect it skips points
outside it. `stepK` is one iteration, given whether the point is kept (`kp`); `encloseFold` is
the loop. Without a clip, the C seeds the bounds from `points[0]` and loops from 1, which is
the same as folding from "nothing added" with every point kept. -/

structure Acc where
  added : Bool
  minx : I32
  maxx : I32
  miny : I32
  maxy : I32

/-- One loop iteration. `if (x < minx) minx = x; else if (x > maxx) maxx = x;` (same for y). -/
def stepK (a : Acc) (px py : I32) (kp : Bool) : Acc :=
  if !kp then a
  else if !a.added then ⟨true, px, px, py, py⟩
  else
    ⟨true,
     (if px.slt a.minx then px else a.minx),
     (if px.slt a.minx then a.maxx else if a.maxx.slt px then px else a.maxx),
     (if py.slt a.miny then py else a.miny),
     (if py.slt a.miny then a.maxy else if a.maxy.slt py then py else a.maxy)⟩

def encloseFold (keep : I32 → I32 → Bool) (a : Acc) : List (I32 × I32) → Acc
  | [] => a
  | p :: ps => encloseFold keep (stepK a p.1 p.2 (keep p.1 p.2)) ps

/-- `x < clip_minx || x > clip_maxx || ...` negated: the point is kept. -/
def inClip (cminx cminy cmaxx cmaxy : I32) (px py : I32) : Bool :=
  !(px.slt cminx || cmaxx.slt px || py.slt cminy || cmaxy.slt py)

/-- The end of `SDL_GetRectEnclosingPoints` once the bounds are known: the fixed code first
checks that the span fits (F-012). Returns (ok, rect, ub). -/
def encloseFinal (fixed : Bool) (a : Acc) : Out :=
  if !a.added then ⟨false, ⟨0, 0, 0, 0⟩, false⟩
  else if fixed && ((wide INT_MAX).slt (wide a.maxx - wide a.minx + 1) ||
                    (wide INT_MAX).slt (wide a.maxy - wide a.miny + 1)) then
    ⟨false, ⟨0, 0, 0, 0⟩, false⟩
  else
    let dx := a.maxx - a.minx
    let dy := a.maxy - a.miny
    ⟨true, ⟨a.minx, a.miny, dx + 1, dy + 1⟩,
     a.maxx.ssubOverflow a.minx || dx.saddOverflow 1 ||
     a.maxy.ssubOverflow a.miny || dy.saddOverflow 1⟩

/-- `SDL_GetRectEnclosingPoints(points, count, clip, &result)`. -/
def enclose (fixed : Bool) (ps : List (I32 × I32)) (clip : Option R) : Out :=
  match ps, clip with
  | [], _ => ⟨false, ⟨0, 0, 0, 0⟩, false⟩                        -- count < 1
  | _, some c =>
    if fixed && canOverflow true c then ⟨false, ⟨0, 0, 0, 0⟩, false⟩ else
    -- clip_maxx = clip->x + clip->w - 1, computed before the empty check
    let ubc := c.x.saddOverflow c.w || (c.x + c.w).ssubOverflow 1 ||
               c.y.saddOverflow c.h || (c.y + c.h).ssubOverflow 1
    if empty c then ⟨false, ⟨0, 0, 0, 0⟩, ubc⟩ else
    let o := encloseFinal fixed
      (encloseFold (inClip c.x c.y (c.x + c.w - 1) (c.y + c.h - 1)) ⟨false, 0, 0, 0, 0⟩ ps)
    ⟨o.ok, o.r, ubc || o.ub⟩
  | _, none => encloseFinal fixed (encloseFold (fun _ _ => true) ⟨false, 0, 0, 0, 0⟩ ps)

/-- The bounds cover the point. -/
def covers (a : Acc) (px py : I32) : Bool :=
  a.added && a.minx.sle px && px.sle a.maxx && a.miny.sle py && py.sle a.maxy

/-- The bounds are ordered (true once a point was added). -/
def ordered (a : Acc) : Bool := !a.added || (a.minx.sle a.maxx && a.miny.sle a.maxy)

/-- The bounds lie in the box `[bx0, bx1] × [by0, by1]`. -/
def inBox (bx0 by0 bx1 by1 : I32) (a : Acc) : Bool :=
  !a.added || (bx0.sle a.minx && a.maxx.sle bx1 && by0.sle a.miny && a.maxy.sle by1)

macro "acc_decide" : tactic => `(tactic| (
  simp only [stepK, covers, ordered, inBox, inClip, apply_ite Acc.added, apply_ite Acc.minx,
    apply_ite Acc.maxx, apply_ite Acc.miny, apply_ite Acc.maxy, Bool.not_eq_true'] at *
  bv_decide))

/-- One step keeps the bounds ordered, keeps covering what they covered, and covers a kept
point. -/
theorem step_ordered (a : Acc) (px py : I32) (kp : Bool) :
    ordered a = true → ordered (stepK a px py kp) = true := by
  cases a; intro h; acc_decide

theorem step_keeps_cover (a : Acc) (px py qx qy : I32) (kp : Bool) :
    ordered a = true → covers a qx qy = true → covers (stepK a px py kp) qx qy = true := by
  cases a; intro h1 h2; acc_decide

theorem step_covers_kept (a : Acc) (px py : I32) :
    ordered a = true → covers (stepK a px py true) px py = true := by
  cases a; intro h; acc_decide

/-- A step adds only kept points, so if every kept point is in the box, the bounds stay in it. -/
theorem step_in_box (a : Acc) (px py bx0 by0 bx1 by1 : I32) (kp : Bool) :
    inBox bx0 by0 bx1 by1 a = true →
    (kp = true → (bx0.sle px && px.sle bx1 && by0.sle py && py.sle by1) = true) →
    inBox bx0 by0 bx1 by1 (stepK a px py kp) = true := by
  cases a; intro h1 h2
  cases kp
  · acc_decide
  · have h3 := h2 rfl; acc_decide

theorem fold_ordered (keep : I32 → I32 → Bool) (ps : List (I32 × I32)) (a : Acc) :
    ordered a = true → ordered (encloseFold keep a ps) = true := by
  induction ps generalizing a with
  | nil => exact id
  | cons p ps ih => intro h; exact ih _ (step_ordered _ _ _ _ h)

theorem fold_keeps_cover (keep : I32 → I32 → Bool) (ps : List (I32 × I32)) (a : Acc) (qx qy : I32) :
    ordered a = true → covers a qx qy = true → covers (encloseFold keep a ps) qx qy = true := by
  induction ps generalizing a with
  | nil => intro _ h; exact h
  | cons p ps ih =>
    intro h1 h2
    exact ih _ (step_ordered _ _ _ _ h1) (step_keeps_cover _ _ _ _ _ _ h1 h2)

/-- After the loop, every kept point is covered by the bounds. -/
theorem fold_covers (keep : I32 → I32 → Bool) (ps : List (I32 × I32)) (a : Acc) :
    ordered a = true → ∀ p ∈ ps, keep p.1 p.2 = true →
      covers (encloseFold keep a ps) p.1 p.2 = true := by
  induction ps generalizing a with
  | nil => intro _ p hp; cases hp
  | cons q ps ih =>
    intro h p hp hk
    simp only [encloseFold]
    rcases List.mem_cons.mp hp with rfl | hp
    · rw [hk]
      exact fold_keeps_cover _ _ _ _ _ (step_ordered _ _ _ _ h) (step_covers_kept _ _ _ h)
    · exact ih _ (step_ordered _ _ _ _ h) p hp hk

theorem fold_in_box (keep : I32 → I32 → Bool) (ps : List (I32 × I32)) (a : Acc) (bx0 by0 bx1 by1 : I32)
    (hk : ∀ px py, keep px py = true → (bx0.sle px && px.sle bx1 && by0.sle py && py.sle by1) = true) :
    inBox bx0 by0 bx1 by1 a = true → inBox bx0 by0 bx1 by1 (encloseFold keep a ps) = true := by
  induction ps generalizing a with
  | nil => exact id
  | cons p ps ih =>
    intro h
    exact ih _ (step_in_box _ _ _ _ _ _ _ _ h (hk p.1 p.2))

/-- The fixed final step never overflows, and its rect contains everything the bounds cover. -/
theorem final_no_ub (a : Acc) : ordered a = true → (encloseFinal true a).ub = false := by
  cases a; intro h
  simp only [encloseFinal, ordered, wide, INT_MAX, apply_ite Out.ub, ite_true, ite_false,
    Bool.true_and, Bool.not_eq_true'] at *; bv_decide

theorem final_contains (a : Acc) (qx qy : I32) :
    ordered a = true → (encloseFinal true a).ok = true → covers a qx qy = true →
      mem (encloseFinal true a).r qx qy = true := by
  cases a; intro h1 h2 h3
  simp only [encloseFinal, ordered, covers, mem, wide, INT_MAX, apply_ite Out.ok, apply_ite Out.r,
    apply_ite R.x, apply_ite R.y, apply_ite R.w, apply_ite R.h, ite_true, ite_false, Bool.true_and,
    Bool.not_eq_true'] at *
  bv_decide

/-- The final rect stays inside a box that holds the bounds. -/
theorem final_in_box (a : Acc) (bx0 by0 bx1 by1 : I32) :
    ordered a = true → inBox bx0 by0 bx1 by1 a = true → (encloseFinal true a).ok = true →
      sub (encloseFinal true a).r ⟨bx0, by0, bx1 - bx0 + 1, by1 - by0 + 1⟩ = true ∨
      (wide INT_MAX).slt (wide bx1 - wide bx0 + 1) ∨ (wide INT_MAX).slt (wide by1 - wide by0 + 1) := by
  cases a; intro h0 h1 h2
  simp only [encloseFinal, ordered, inBox, sub, wide, INT_MAX, apply_ite Out.ok, apply_ite Out.r,
    apply_ite R.x, apply_ite R.y, apply_ite R.w, apply_ite R.h, ite_true, ite_false, Bool.true_and,
    Bool.not_eq_true'] at *
  bv_decide

/-- The pre-fix final step overflows on points `INT_MIN` and `INT_MAX` (F-012). -/
theorem final_prefix_ub_example :
    (encloseFinal false ⟨true, INT_MIN, INT_MAX, 0, 0⟩).ub = true := by
  simp only [encloseFinal, INT_MIN, INT_MAX]; bv_decide

/-- The clip bounds `clip->x + clip->w - 1` never overflow on a clip that passes the fixed
guard. -/
theorem clip_no_ub (c : R) : canOverflow true c = false →
    (c.x.saddOverflow c.w || (c.x + c.w).ssubOverflow 1 ||
     c.y.saddOverflow c.h || (c.y + c.h).ssubOverflow 1) = false := by
  cases c; intro h; rect_decide

/-- A point in a guarded clip rect passes the C's clip test. -/
theorem mem_inClip (c : R) (px py : I32) : canOverflow true c = false → mem c px py = true →
    inClip c.x c.y (c.x + c.w - 1) (c.y + c.h - 1) px py = true := by
  cases c; intro h1 h2; simp only [inClip] at *; rect_decide

/-- A kept point is in the clip box (by definition of the clip test). -/
theorem inClip_box (c : R) : ∀ px py, inClip c.x c.y (c.x + c.w - 1) (c.y + c.h - 1) px py = true →
    (c.x.sle px && px.sle (c.x + c.w - 1) && c.y.sle py && py.sle (c.y + c.h - 1)) = true := by
  cases c; intro px py h; simp only [inClip] at *; bv_decide

/-- For a guarded non-empty clip, the box `[x, x+w-1] × [y, y+h-1]` is exactly the clip rect. -/
theorem clip_box_sub (c r : R) : canOverflow true c = false → empty c = false →
    (sub r ⟨c.x, c.y, (c.x + c.w - 1) - c.x + 1, (c.y + c.h - 1) - c.y + 1⟩ = true ∨
     (wide INT_MAX).slt (wide (c.x + c.w - 1) - wide c.x + 1) ∨
     (wide INT_MAX).slt (wide (c.y + c.h - 1) - wide c.y + 1)) → sub r c = true := by
  cases c; cases r; intro h1 h2 h3; rect_decide

/-- **`SDL_GetRectEnclosingPoints` without a clip**: never overflows, and when it succeeds the
result contains every point. -/
theorem enclose_noclip (ps : List (I32 × I32)) :
    (enclose true ps none).ub = false ∧
    ((enclose true ps none).ok = true → ∀ p ∈ ps, mem (enclose true ps none).r p.1 p.2 = true) := by
  cases ps with
  | nil => simp [enclose]
  | cons q qs =>
    simp only [enclose]
    refine ⟨final_no_ub _ (fold_ordered _ _ _ rfl), fun hok p hp => ?_⟩
    exact final_contains _ _ _ (fold_ordered _ _ _ rfl) hok
      (fold_covers (fun _ _ => true) _ _ rfl p hp rfl)

/-- **`SDL_GetRectEnclosingPoints` with a clip**: never overflows (the clip passes the fixed
guard or is rejected), and when it succeeds the result contains every point inside the clip and
lies inside the clip. -/
theorem enclose_clip (ps : List (I32 × I32)) (c : R) :
    (enclose true ps (some c)).ub = false ∧
    ((enclose true ps (some c)).ok = true →
      (∀ p ∈ ps, mem c p.1 p.2 = true → mem (enclose true ps (some c)).r p.1 p.2 = true) ∧
      sub (enclose true ps (some c)).r c = true) := by
  cases ps with
  | nil => simp [enclose]
  | cons q qs =>
    simp only [enclose, Bool.true_and]
    by_cases hg : canOverflow true c = true
    · simp [hg]
    · have hg' : canOverflow true c = false := by simpa using hg
      simp only [hg', ite_false, Bool.false_eq_true]
      by_cases he : empty c = true
      · have hc := clip_no_ub c hg'
        simp only [Bool.or_eq_false_iff] at hc
        simp only [he, ite_true, Bool.or_eq_false_iff]
        exact ⟨hc, fun h => absurd h (by decide)⟩
      · have he' : empty c = false := by simpa using he
        simp only [he', ite_false, Bool.false_eq_true, clip_no_ub c hg', Bool.false_or]
        have hord := fold_ordered (inClip c.x c.y (c.x + c.w - 1) (c.y + c.h - 1))
          (q :: qs) ⟨false, 0, 0, 0, 0⟩ rfl
        refine ⟨final_no_ub _ hord, fun hok => ⟨fun p hp hm => ?_, ?_⟩⟩
        · exact final_contains _ _ _ hord hok
            (fold_covers _ _ _ rfl p hp (mem_inClip c p.1 p.2 hg' hm))
        · have hbox := fold_in_box (inClip c.x c.y (c.x + c.w - 1) (c.y + c.h - 1)) (q :: qs)
            ⟨false, 0, 0, 0, 0⟩ c.x c.y (c.x + c.w - 1) (c.y + c.h - 1) (inClip_box c) rfl
          exact clip_box_sub c _ hg' he' (final_in_box _ _ _ _ _ hord hbox hok)

end SDLVerif.Rect
