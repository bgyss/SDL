/-
`SDL_GetRectAndLineIntersection` for `SDL_Rect` (src/video/SDL_rect_impl.h, Cohen–Sutherland
clipping), the code in this fork since cce7d368b (F-014).

The interpolation the C does at each step is, in `Sint64`,
  `x = (int)(x1 + ((Sint64)x2 - x1) * ((Sint64)y - y1) / ((Sint64)y2 - y1))`
where `/` truncates toward zero. This file models the loop over `Int`, with `Int.tdiv` for the
C division, and proves that on every input the fixed guard accepts:
* every 64-bit intermediate fits in `Sint64` (no signed overflow), every divisor is non-zero
  (the `SDL_assert`s in the C can never fire), and every value cast back to `int` fits, so the
  `Int` model is exactly what the C computes;
* the loop terminates: `|x2 - x1| + |y2 - y1|` drops strictly at each step;
* when it returns true, both endpoints lie inside the rect.

The key fact is that every clipped point lands on the segment's own bounding box, so all
coordinates stay strictly within (SDL_MIN_SINT32/2, SDL_MAX_SINT32/2), the range the fixed
code checks the endpoints against. The old code had no endpoint check and computed `x2 - x1` in
`int` (F-014).
-/
namespace SDLVerif.RectLine

/-! ## The interpolation step stays between the endpoints -/

/-- Truncating division of `D * e` by `d`, where `e/d ∈ [0, 1]`, lies between 0 and `D`. -/
theorem tdiv_frac_pos (D e d : Int) (hd : 0 < d) (he0 : 0 ≤ e) (hed : e ≤ d) :
    (0 ≤ D → 0 ≤ (D * e).tdiv d ∧ (D * e).tdiv d ≤ D) ∧
    (D ≤ 0 → D ≤ (D * e).tdiv d ∧ (D * e).tdiv d ≤ 0) := by
  have key : ∀ D' : Int, 0 ≤ D' → 0 ≤ (D' * e).tdiv d ∧ (D' * e).tdiv d ≤ D' := by
    intro D' hD
    have hn : 0 ≤ D' * e := Int.mul_nonneg hD he0
    rw [Int.tdiv_eq_ediv]
    simp only [hn, true_or, ite_true, Int.add_zero]
    exact ⟨Int.ediv_nonneg hn (Int.le_of_lt hd),
      Int.ediv_le_of_le_mul hd (Int.mul_le_mul_of_nonneg_left hed hD)⟩
  refine ⟨key D, fun hD => ?_⟩
  have h := key (-D) (by omega)
  rw [Int.neg_mul, Int.neg_tdiv] at h
  omega

/-- The same with `e/d ∈ [0, 1]` for any sign of `d`. -/
theorem tdiv_frac (D e d : Int)
    (h : (0 < d ∧ 0 ≤ e ∧ e ≤ d) ∨ (d < 0 ∧ d ≤ e ∧ e ≤ 0)) :
    (0 ≤ D → 0 ≤ (D * e).tdiv d ∧ (D * e).tdiv d ≤ D) ∧
    (D ≤ 0 → D ≤ (D * e).tdiv d ∧ (D * e).tdiv d ≤ 0) := by
  rcases h with ⟨hd, he0, hed⟩ | ⟨hd, hde, he0⟩
  · exact tdiv_frac_pos D e d hd he0 hed
  · have h := tdiv_frac_pos D (-e) (-d) (by omega) (by omega) (by omega)
    rw [Int.mul_neg, Int.neg_tdiv, Int.tdiv_neg, Int.neg_neg] at h
    exact h

/-- `a1 + (a2 - a1) * (b - b1) / (b2 - b1)` with `b` between `b1` and `b2` (and `b ≠ b1` or
not, either way) lies between `a1` and `a2`. -/
theorem interp_between (a1 a2 b1 b2 b : Int)
    (h : (b1 < b2 ∧ b1 ≤ b ∧ b ≤ b2) ∨ (b2 < b1 ∧ b2 ≤ b ∧ b ≤ b1)) :
    let v := a1 + ((a2 - a1) * (b - b1)).tdiv (b2 - b1)
    min a1 a2 ≤ v ∧ v ≤ max a1 a2 := by
  intro v
  have hf := tdiv_frac (a2 - a1) (b - b1) (b2 - b1) (by omega)
  simp only [v, Int.min_def, Int.max_def]
  generalize ((a2 - a1) * (b - b1)).tdiv (b2 - b1) = q at *
  by_cases ha : a1 ≤ a2
  · have := hf.1 (by omega); split <;> omega
  · have := hf.2 (by omega); split <;> omega

/-- `interp_between` without `min`/`max`, in the form `omega` uses directly. -/
theorem interp_between' (a1 a2 b1 b2 b : Int) :
    ((b1 < b2 ∧ b1 ≤ b ∧ b ≤ b2) ∨ (b2 < b1 ∧ b2 ≤ b ∧ b ≤ b1)) →
    (a1 ≤ a2 → a1 ≤ a1 + ((a2 - a1) * (b - b1)).tdiv (b2 - b1) ∧
                a1 + ((a2 - a1) * (b - b1)).tdiv (b2 - b1) ≤ a2) ∧
    (a2 ≤ a1 → a2 ≤ a1 + ((a2 - a1) * (b - b1)).tdiv (b2 - b1) ∧
                a1 + ((a2 - a1) * (b - b1)).tdiv (b2 - b1) ≤ a1) := by
  intro h
  have hv := interp_between a1 a2 b1 b2 b h
  simp only at hv
  generalize a1 + ((a2 - a1) * (b - b1)).tdiv (b2 - b1) = v at *
  omega

/-- `|a * b| < 2^62` when `|a|, |b| < 2^31`: the products in the interpolation fit in `Sint64`
with room to spare. -/
theorem prod_bound (a b : Int) (ha : a.natAbs < 2 ^ 31) (hb : b.natAbs < 2 ^ 31) :
    (a * b).natAbs < 2 ^ 62 := by
  rw [Int.natAbs_mul]
  calc a.natAbs * b.natAbs < 2 ^ 31 * 2 ^ 31 := Nat.mul_lt_mul'' ha hb
    _ = 2 ^ 62 := rfl

/-! ## The model -/

/-- The bounds of the open range the fixed code requires of the endpoints:
`SDL_MIN_SINT32 / 2 < v < SDL_MAX_SINT32 / 2`. -/
def L : Int := -1073741824
def H : Int := 1073741823

def inRange (v : Int) : Prop := L < v ∧ v < H

/-- `rectx1 = rect->x`, `rectx2 = rect->x + rect->w - 1` (same for y). -/
structure Box where
  x1 : Int
  y1 : Int
  x2 : Int
  y2 : Int

/-- The endpoints `(x1, y1)`, `(x2, y2)` as the loop updates them. -/
structure Seg where
  x1 : Int
  y1 : Int
  x2 : Int
  y2 : Int

/-- `COMPUTEOUTCODE`: TOP and BOTTOM exclude each other, as do LEFT and RIGHT. -/
structure OC where
  top : Bool
  bot : Bool
  left : Bool
  right : Bool

def oc (b : Box) (x y : Int) : OC :=
  ⟨decide (y < b.y1), !decide (y < b.y1) && decide (b.y2 < y),
   decide (x < b.x1), !decide (x < b.x1) && decide (b.x2 < x)⟩

def OC.nz (o : OC) : Bool := o.top || o.bot || o.left || o.right

/-- `outcode1 & outcode2`. -/
def meet (o p : OC) : Bool :=
  (o.top && p.top) || (o.bot && p.bot) || (o.left && p.left) || (o.right && p.right)

/-- `x1 + ((Sint64)x2 - x1) * ((Sint64)y - y1) / ((Sint64)y2 - y1)` and the y counterpart.
Both endpoint branches of the C use these same formulas, from `(x1, y1)`. -/
def ix (s : Seg) (y : Int) : Int := s.x1 + ((s.x2 - s.x1) * (y - s.y1)).tdiv (s.y2 - s.y1)
def iy (s : Seg) (x : Int) : Int := s.y1 + ((s.y2 - s.y1) * (x - s.x1)).tdiv (s.x2 - s.x1)

/-- Where the C moves an endpoint with (non-zero) outcode `o`. -/
def target (b : Box) (s : Seg) (o : OC) : Int × Int :=
  if o.top then (ix s b.y1, b.y1)
  else if o.bot then (ix s b.y2, b.y2)
  else if o.left then (b.x1, iy s b.x1)
  else (b.x2, iy s b.x2)

/-- One loop iteration: move endpoint 1 if it is outside, else endpoint 2. -/
def step (b : Box) (s : Seg) : Seg :=
  let o1 := oc b s.x1 s.y1
  if o1.nz then
    let t := target b s o1
    ⟨t.1, t.2, s.x2, s.y2⟩
  else
    let t := target b s (oc b s.x2 s.y2)
    ⟨s.x1, s.y1, t.1, t.2⟩

/-- What one iteration needs to be defined behavior with an exact result: a non-zero divisor,
factors whose product fits in `Sint64` (|a|, |b| < 2^31, see `prod_bound`), and a result that
fits in `int`. -/
def safeTarget (b : Box) (s : Seg) (o : OC) : Prop :=
  if o.top || o.bot then
    let y := if o.top then b.y1 else b.y2
    s.y2 - s.y1 ≠ 0 ∧ (s.x2 - s.x1).natAbs < 2 ^ 31 ∧ (y - s.y1).natAbs < 2 ^ 31 ∧ inRange (ix s y)
  else
    let x := if o.left then b.x1 else b.x2
    s.x2 - s.x1 ≠ 0 ∧ (s.y2 - s.y1).natAbs < 2 ^ 31 ∧ (x - s.x1).natAbs < 2 ^ 31 ∧ inRange (iy s x)

def stepSafe (b : Box) (s : Seg) : Prop :=
  let o1 := oc b s.x1 s.y1
  if o1.nz then safeTarget b s o1 else safeTarget b s (oc b s.x2 s.y2)

/-- The `while (outcode1 || outcode2)` loop, with fuel. `none`: the fuel ran out. -/
def loop (b : Box) : Nat → Seg → Option (Bool × Seg)
  | fuel, s =>
    let o1 := oc b s.x1 s.y1
    let o2 := oc b s.x2 s.y2
    if !(o1.nz || o2.nz) then some (true, s)
    else if meet o1 o2 then some (false, s)
    else match fuel with
      | 0 => none
      | n + 1 => loop b n (step b s)

/-- Every iteration the loop executes is safe. -/
def loopSafe (b : Box) : Nat → Seg → Prop
  | fuel, s =>
    let o1 := oc b s.x1 s.y1
    let o2 := oc b s.x2 s.y2
    if !(o1.nz || o2.nz) then True
    else if meet o1 o2 then True
    else match fuel with
      | 0 => True
      | n + 1 => stepSafe b s ∧ loopSafe b n (step b s)

def segIn (s : Seg) : Prop := inRange s.x1 ∧ inRange s.y1 ∧ inRange s.x2 ∧ inRange s.y2

/-- What the rect guard and the empty-rect check give: `L < rect->x < H`, `0 < rect->w`. -/
def boxOk (b : Box) : Prop := inRange b.x1 ∧ inRange b.y1 ∧ b.x1 ≤ b.x2 ∧ b.y1 ≤ b.y2

def measure (s : Seg) : Nat := (s.x2 - s.x1).natAbs + (s.y2 - s.y1).natAbs

/-! ## One step -/

/-- The generic interpolation step: clipping coordinate `c` between `b1` and `b2`, all inputs
in range. The divisor is non-zero, the factors are small, the result is between `a1` and `a2`
and therefore in range. -/
theorem interp_safe (a1 a2 b1 b2 c : Int)
    (ha1 : inRange a1) (ha2 : inRange a2) (hb1 : inRange b1) (hb2 : inRange b2)
    (hc : (b1 < b2 ∧ b1 ≤ c ∧ c ≤ b2) ∨ (b2 < b1 ∧ b2 ≤ c ∧ c ≤ b1)) :
    b2 - b1 ≠ 0 ∧ (a2 - a1).natAbs < 2 ^ 31 ∧ (c - b1).natAbs < 2 ^ 31 ∧
    min a1 a2 ≤ a1 + ((a2 - a1) * (c - b1)).tdiv (b2 - b1) ∧
    a1 + ((a2 - a1) * (c - b1)).tdiv (b2 - b1) ≤ max a1 a2 := by
  have hv := interp_between a1 a2 b1 b2 c hc
  simp only [inRange, L, H] at *
  refine ⟨by omega, by omega, by omega, hv.1, hv.2⟩

/-- Moving endpoint 1 to `(v, c)`, where `c` lies strictly past `b1` toward `b2`. The
divisor is non-zero, the factors are small, the new point is in range, and the measure drops.
(Used with `a = x, b = y` for TOP/BOTTOM and `a = y, b = x` for LEFT/RIGHT.) -/
theorem move1 (a1 a2 b1 b2 c : Int)
    (ha1 : L < a1 ∧ a1 < H) (ha2 : L < a2 ∧ a2 < H) (hb1 : L < b1 ∧ b1 < H)
    (hb2 : L < b2 ∧ b2 < H) (hc : L < c ∧ c < H)
    (hdir : (b1 < c ∧ c ≤ b2) ∨ (b2 ≤ c ∧ c < b1)) :
    b2 - b1 ≠ 0 ∧ (a2 - a1).natAbs < 2 ^ 31 ∧ (c - b1).natAbs < 2 ^ 31 ∧
    (L < a1 + ((a2 - a1) * (c - b1)).tdiv (b2 - b1) ∧ a1 + ((a2 - a1) * (c - b1)).tdiv (b2 - b1) < H) ∧
    (a2 - (a1 + ((a2 - a1) * (c - b1)).tdiv (b2 - b1))).natAbs + (b2 - c).natAbs <
      (a2 - a1).natAbs + (b2 - b1).natAbs := by
  have f := interp_between' a1 a2 b1 b2 c (by omega)
  generalize ((a2 - a1) * (c - b1)).tdiv (b2 - b1) = q at *
  simp only [L, H] at *
  omega

/-- Moving endpoint 2 to `(v, c)` (computed from endpoint 1, as the C does), where `c` lies
strictly past `b2` toward `b1`. -/
theorem move2 (a1 a2 b1 b2 c : Int)
    (ha1 : L < a1 ∧ a1 < H) (ha2 : L < a2 ∧ a2 < H) (hb1 : L < b1 ∧ b1 < H)
    (hb2 : L < b2 ∧ b2 < H) (hc : L < c ∧ c < H)
    (hdir : (b2 < c ∧ c ≤ b1) ∨ (b1 ≤ c ∧ c < b2)) :
    b2 - b1 ≠ 0 ∧ (a2 - a1).natAbs < 2 ^ 31 ∧ (c - b1).natAbs < 2 ^ 31 ∧
    (L < a1 + ((a2 - a1) * (c - b1)).tdiv (b2 - b1) ∧ a1 + ((a2 - a1) * (c - b1)).tdiv (b2 - b1) < H) ∧
    ((a1 + ((a2 - a1) * (c - b1)).tdiv (b2 - b1)) - a1).natAbs + (c - b1).natAbs <
      (a2 - a1).natAbs + (b2 - b1).natAbs := by
  have f := interp_between' a1 a2 b1 b2 c (by omega)
  generalize ((a2 - a1) * (c - b1)).tdiv (b2 - b1) = q at *
  simp only [L, H] at *
  omega

/-- Unfold one step for given outcode bits. -/
macro "step_simp" : tactic => `(tactic| (
  simp only [stepSafe, step, safeTarget, target, measure, ix, iy, oc, OC.nz, segIn, inRange,
    Bool.or_eq_true, Bool.and_eq_true, Bool.not_eq_true', decide_eq_true_eq,
    decide_eq_false_iff_not, Bool.not_eq_false', Bool.or_false, Bool.false_or, Bool.or_true,
    Bool.true_or, Bool.and_false, Bool.false_and, Bool.and_true, Bool.true_and, Bool.not_true,
    Bool.not_false, decide_true, decide_false, ite_true, ite_false,
    true_and, and_true, not_true, not_false_eq_true, *] at *))

/-- **One iteration**: on segments in range with a non-empty guarded rect, while some outcode is
set and the outcodes don't meet, the step is safe, stays in range, and shrinks the measure. -/
theorem step_ok (b : Box) (s : Seg) (hb : boxOk b) (hs : segIn s)
    (hnz : ((oc b s.x1 s.y1).nz || (oc b s.x2 s.y2).nz) = true)
    (hm : meet (oc b s.x1 s.y1) (oc b s.x2 s.y2) = false) :
    stepSafe b s ∧ segIn (step b s) ∧ measure (step b s) < measure s := by
  obtain ⟨bx1, by1, bx2, by2⟩ := b
  obtain ⟨x1, y1, x2, y2⟩ := s
  simp only [boxOk, segIn, inRange] at hb hs
  simp only [oc, OC.nz, meet, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq,
    Bool.not_eq_true', decide_eq_false_iff_not, Bool.or_eq_false_iff, Bool.and_eq_false_iff,
    Bool.not_eq_false'] at hnz hm
  -- Endpoint 1 is outside: the C moves it.
  by_cases t1 : y1 < by1
  · -- TOP: endpoint 2 is not above, so by1 ∈ (y1, y2]
    have m := move1 x1 x2 y1 y2 by1 ⟨by omega, by omega⟩ ⟨by omega, by omega⟩
      ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ (by omega)
    simp only [stepSafe, step, safeTarget, target, measure, ix, iy, oc, OC.nz, segIn, inRange, t1,
      decide_true, Bool.true_or, ite_true, Bool.true_and]
    refine ⟨⟨m.1, m.2.1, m.2.2.1, m.2.2.2.1⟩, ⟨m.2.2.2.1, ⟨by omega, by omega⟩, ⟨by omega, by omega⟩,
      ⟨by omega, by omega⟩⟩, ?_⟩
    have := m.2.2.2.2; omega
  by_cases b1 : by2 < y1
  · -- BOTTOM: endpoint 2 is not below, so by2 ∈ [y2, y1)
    have m := move1 x1 x2 y1 y2 by2 ⟨by omega, by omega⟩ ⟨by omega, by omega⟩
      ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ (by omega)
    simp only [stepSafe, step, safeTarget, target, measure, ix, iy, oc, OC.nz, segIn, inRange, t1, b1,
      decide_true, decide_false, Bool.not_false, Bool.true_and, Bool.false_or, Bool.true_or,
      ite_true, ite_false, Bool.false_eq_true]
    refine ⟨⟨m.1, m.2.1, m.2.2.1, m.2.2.2.1⟩, ⟨m.2.2.2.1, ⟨by omega, by omega⟩, ⟨by omega, by omega⟩,
      ⟨by omega, by omega⟩⟩, ?_⟩
    have := m.2.2.2.2; omega
  by_cases l1 : x1 < bx1
  · -- LEFT: bx1 ∈ (x1, x2]
    have m := move1 y1 y2 x1 x2 bx1 ⟨by omega, by omega⟩ ⟨by omega, by omega⟩
      ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ (by omega)
    simp only [stepSafe, step, safeTarget, target, measure, ix, iy, oc, OC.nz, segIn, inRange, t1, b1, l1,
      decide_true, decide_false, Bool.not_false, Bool.true_and, Bool.false_or, Bool.true_or,
      Bool.and_false, Bool.or_false, ite_true, ite_false, Bool.false_eq_true]
    refine ⟨⟨m.1, m.2.1, m.2.2.1, m.2.2.2.1⟩, ⟨⟨by omega, by omega⟩, m.2.2.2.1, ⟨by omega, by omega⟩,
      ⟨by omega, by omega⟩⟩, ?_⟩
    have := m.2.2.2.2; omega
  by_cases r1 : bx2 < x1
  · -- RIGHT: bx2 ∈ [x2, x1)
    have m := move1 y1 y2 x1 x2 bx2 ⟨by omega, by omega⟩ ⟨by omega, by omega⟩
      ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ (by omega)
    simp only [stepSafe, step, safeTarget, target, measure, ix, iy, oc, OC.nz, segIn, inRange, t1, b1, l1, r1,
      decide_true, decide_false, Bool.not_false, Bool.true_and, Bool.false_or, Bool.true_or,
      Bool.and_false, Bool.or_false, ite_true, ite_false, Bool.false_eq_true]
    refine ⟨⟨m.1, m.2.1, m.2.2.1, m.2.2.2.1⟩, ⟨⟨by omega, by omega⟩, m.2.2.2.1, ⟨by omega, by omega⟩,
      ⟨by omega, by omega⟩⟩, ?_⟩
    have := m.2.2.2.2; omega
  -- Endpoint 1 is inside; endpoint 2 is outside and the C moves it.
  by_cases t2 : y2 < by1
  · have m := move2 x1 x2 y1 y2 by1 ⟨by omega, by omega⟩ ⟨by omega, by omega⟩
      ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ (by omega)
    simp only [stepSafe, step, safeTarget, target, measure, ix, iy, oc, OC.nz, segIn, inRange, t1, b1, l1, r1, t2,
      decide_true, decide_false, Bool.not_false, Bool.true_and, Bool.false_or, Bool.true_or,
      Bool.and_false, Bool.or_false, ite_true, ite_false, Bool.false_eq_true]
    refine ⟨⟨m.1, m.2.1, m.2.2.1, m.2.2.2.1⟩, ⟨⟨by omega, by omega⟩, ⟨by omega, by omega⟩, m.2.2.2.1,
      ⟨by omega, by omega⟩⟩, ?_⟩
    have := m.2.2.2.2; omega
  by_cases b2 : by2 < y2
  · have m := move2 x1 x2 y1 y2 by2 ⟨by omega, by omega⟩ ⟨by omega, by omega⟩
      ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ (by omega)
    simp only [stepSafe, step, safeTarget, target, measure, ix, iy, oc, OC.nz, segIn, inRange, t1, b1, l1, r1, t2, b2,
      decide_true, decide_false, Bool.not_false, Bool.true_and, Bool.false_or, Bool.true_or,
      Bool.and_false, Bool.or_false, ite_true, ite_false, Bool.false_eq_true]
    refine ⟨⟨m.1, m.2.1, m.2.2.1, m.2.2.2.1⟩, ⟨⟨by omega, by omega⟩, ⟨by omega, by omega⟩, m.2.2.2.1,
      ⟨by omega, by omega⟩⟩, ?_⟩
    have := m.2.2.2.2; omega
  by_cases l2 : x2 < bx1
  · have m := move2 y1 y2 x1 x2 bx1 ⟨by omega, by omega⟩ ⟨by omega, by omega⟩
      ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ (by omega)
    simp only [stepSafe, step, safeTarget, target, measure, ix, iy, oc, OC.nz, segIn, inRange, t1, b1, l1, r1, t2, b2, l2,
      decide_true, decide_false, Bool.not_false, Bool.true_and, Bool.false_or, Bool.true_or,
      Bool.and_false, Bool.or_false, ite_true, ite_false, Bool.false_eq_true]
    refine ⟨⟨m.1, m.2.1, m.2.2.1, m.2.2.2.1⟩, ⟨⟨by omega, by omega⟩, ⟨by omega, by omega⟩,
      ⟨by omega, by omega⟩, m.2.2.2.1⟩, ?_⟩
    have := m.2.2.2.2; omega
  have r2 : bx2 < x2 := by omega
  have m := move2 y1 y2 x1 x2 bx2 ⟨by omega, by omega⟩ ⟨by omega, by omega⟩
    ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ ⟨by omega, by omega⟩ (by omega)
  simp only [stepSafe, step, safeTarget, target, measure, ix, iy, oc, OC.nz, segIn, inRange, t1, b1, l1, r1, t2, b2, l2, r2,
    decide_true, decide_false, Bool.not_false, Bool.true_and, Bool.false_or, Bool.true_or,
    Bool.and_false, Bool.or_false, ite_true, ite_false, Bool.false_eq_true]
  refine ⟨⟨m.1, m.2.1, m.2.2.1, m.2.2.2.1⟩, ⟨⟨by omega, by omega⟩, ⟨by omega, by omega⟩,
    ⟨by omega, by omega⟩, m.2.2.2.1⟩, ?_⟩
  have := m.2.2.2.2; omega

/-! ## The loop -/

/-- The endpoint is inside the rect (its outcode is zero). -/
def inside (b : Box) (x y : Int) : Prop := b.x1 ≤ x ∧ x ≤ b.x2 ∧ b.y1 ≤ y ∧ y ≤ b.y2

/-- **The loop**: from any segment in range, with fuel larger than its measure, the loop
finishes (never runs out of fuel), every iteration it executes is safe, and when it returns
true both endpoints are inside the rect. -/
theorem loop_ok (b : Box) (hb : boxOk b) :
    ∀ (n : Nat) (s : Seg), segIn s → measure s < n →
      loopSafe b n s ∧ ∃ r, loop b n s = some r ∧
        (r.1 = true → inside b r.2.x1 r.2.y1 ∧ inside b r.2.x2 r.2.y2) := by
  intro n
  induction n with
  | zero => intro s _ h; exact absurd h (Nat.not_lt_zero _)
  | succ n ih =>
    intro s hs hlt
    by_cases hdone : ((oc b s.x1 s.y1).nz || (oc b s.x2 s.y2).nz) = false
    · -- both outcodes zero: return true with the endpoints inside
      have hin : inside b s.x1 s.y1 ∧ inside b s.x2 s.y2 := by
        simp only [oc, OC.nz, Bool.or_eq_false_iff, Bool.and_eq_false_iff, decide_eq_false_iff_not,
          Bool.not_eq_false', decide_eq_true_eq] at hdone
        simp only [inside, boxOk, inRange] at *
        omega
      refine ⟨?_, (true, s), ?_, fun _ => hin⟩
      · simp only [loopSafe, hdone, Bool.not_false, ite_true]
      · simp only [loop, hdone, Bool.not_false, ite_true]
    · have hnz : ((oc b s.x1 s.y1).nz || (oc b s.x2 s.y2).nz) = true := by
        simpa only [Bool.not_eq_false] using hdone
      by_cases hmeet : meet (oc b s.x1 s.y1) (oc b s.x2 s.y2) = true
      · refine ⟨?_, (false, s), ?_, fun h => by simp at h⟩
        · simp only [loopSafe, hnz, hmeet, Bool.not_true, ite_true, ite_false, Bool.false_eq_true]
        · simp only [loop, hnz, hmeet, Bool.not_true, ite_true, ite_false, Bool.false_eq_true]
      · have hm : meet (oc b s.x1 s.y1) (oc b s.x2 s.y2) = false := by
          simpa only [Bool.not_eq_true] using hmeet
        have st := step_ok b s hb hs hnz hm
        have hrec := ih (step b s) st.2.1 (by omega)
        refine ⟨?_, ?_⟩
        · simp only [loopSafe, hnz, hm, Bool.not_true, ite_false, Bool.false_eq_true]
          exact ⟨st.1, hrec.1⟩
        · obtain ⟨r, hr, hin⟩ := hrec.2
          refine ⟨r, ?_, hin⟩
          simp only [loop, hnz, hm, Bool.not_true, ite_false, Bool.false_eq_true]
          exact hr

/-! ## The guards give the loop's preconditions -/

/-- A C `int`. -/
def isInt (v : Int) : Prop := -2147483648 ≤ v ∧ v ≤ 2147483647

/-- `rectx2 = rect->x + rect->w - 1` (and `recty2`) never overflows on a rect that passes the
fixed `SDL_RECT_CAN_OVERFLOW` guard and is not empty, and the box satisfies `boxOk`. -/
theorem rect_box_ok (x y w h : Int)
    (hx : L < x ∧ x < H) (hy : L < y ∧ y < H)
    (hw : 0 < w ∧ w < H) (hh : 0 < h ∧ h < H) :
    isInt (x + w) ∧ isInt (x + w - 1) ∧ isInt (y + h) ∧ isInt (y + h - 1) ∧
    boxOk ⟨x, y, x + w - 1, y + h - 1⟩ := by
  simp only [isInt, boxOk, inRange, L, H] at *
  omega

/-- The fixed code's endpoint check (`SDL_MIN_SINT32 / 2 < v < SDL_MAX_SINT32 / 2` for all four
coordinates) is exactly `segIn`. With `rect_box_ok`, `loop_ok` applies: the Cohen–Sutherland
loop of the fixed `SDL_GetRectAndLineIntersection` terminates within `|x2-x1| + |y2-y1| + 1`
iterations, never overflows `Sint64` or divides by zero, casts only values that fit back to
`int`, and returns endpoints inside the rect. -/
theorem endpoint_check_iff (x1 y1 x2 y2 : Int) :
    segIn ⟨x1, y1, x2, y2⟩ ↔ (L < x1 ∧ x1 < H) ∧ (L < y1 ∧ y1 < H) ∧ (L < x2 ∧ x2 < H) ∧
      (L < y2 ∧ y2 < H) := Iff.rfl

/-! ## The whole function

`clip` is all of `SDL_GetRectAndLineIntersection` for the fixed code: the rect guard, the
empty-rect check, the trivial inside / one-side cases, the horizontal and vertical special
cases, the endpoint check, then the loop. It returns `(result, *X1, *Y1, *X2, *Y2)`; endpoints
the C does not write keep their input values. It is what test/rect_diff.sh runs against the C. -/

/-- The fixed `SDL_RECT_CAN_OVERFLOW` on `int` values. -/
def rectGuardFails (rx ry rw rh : Int) : Bool :=
  decide (rx ≤ L) || decide (H ≤ rx) || decide (ry ≤ L) || decide (H ≤ ry) ||
  decide (H ≤ rw) || decide (H ≤ rh) || decide (rw ≤ L) || decide (rh ≤ L)

def clip (rx ry rw rh x1 y1 x2 y2 : Int) : Bool × Int × Int × Int × Int :=
  let unchanged := (false, x1, y1, x2, y2)
  if rectGuardFails rx ry rw rh then unchanged
  else if rw ≤ 0 ∨ rh ≤ 0 then unchanged
  else
    let rx1 := rx
    let ry1 := ry
    let rx2 := rx + rw - 1
    let ry2 := ry + rh - 1
    if rx1 ≤ x1 ∧ x1 ≤ rx2 ∧ rx1 ≤ x2 ∧ x2 ≤ rx2 ∧ ry1 ≤ y1 ∧ y1 ≤ ry2 ∧ ry1 ≤ y2 ∧ y2 ≤ ry2 then
      (true, x1, y1, x2, y2)
    else if (x1 < rx1 ∧ x2 < rx1) ∨ (x1 > rx2 ∧ x2 > rx2) ∨ (y1 < ry1 ∧ y2 < ry1) ∨
            (y1 > ry2 ∧ y2 > ry2) then unchanged
    else if y1 = y2 then
      let cx := fun x => if x < rx1 then rx1 else if x > rx2 then rx2 else x
      (true, cx x1, y1, cx x2, y2)
    else if x1 = x2 then
      let cy := fun y => if y < ry1 then ry1 else if y > ry2 then ry2 else y
      (true, x1, cy y1, x2, cy y2)
    else if ¬(L < x1 ∧ x1 < H ∧ L < y1 ∧ y1 < H ∧ L < x2 ∧ x2 < H ∧ L < y2 ∧ y2 < H) then
      unchanged
    else
      let s : Seg := ⟨x1, y1, x2, y2⟩
      match loop ⟨rx1, ry1, rx2, ry2⟩ (measure s + 1) s with
      | some (true, t) => (true, t.x1, t.y1, t.x2, t.y2)
      | _ => unchanged

/-- In particular, every product the C forms is below 2^62 in magnitude, so it fits `Sint64`. -/
theorem products_fit (a b : Int) (ha : a.natAbs < 2 ^ 31) (hb : b.natAbs < 2 ^ 31) :
    (a * b).natAbs < 2 ^ 63 := by
  have := prod_bound a b ha hb; omega

end SDLVerif.RectLine
