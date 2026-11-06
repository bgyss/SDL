/-
Gamepad mapping strings: the parser behind every `SDL_AddGamepadMapping`, `SDL_SetGamepadMapping`
and `gamecontrollerdb.txt` entry (src/joystick/SDL_gamepad.c, code since the F-006/F-009/F-022
fixes).

* `parseConfig` transcribes `SDL_PrivateParseGamepadConfigString`: a character loop that fills
  `char szGameButton[20]` and `char szJoystickButton[128]`, calling the element parser at each
  `,` and at the end.
* `parseElement` transcribes `SDL_PrivateParseGamepadElement`: the output name (axis or button,
  optional `+`/`-`) and the input binding (`a<N>`, `b<N>`, `h<D>.<N>`, optional `+`/`-`, `~`).
* Theorems: the buffers stay NUL-terminated (the F-006 bound), spaces are ignored, the element
  parser accepts exactly a stated grammar, and a body built from well-formed elements parses to
  exactly their bindings.
* test/gamepad_diff.sh compares the model's bindings with the real ones that
  `SDL_GetGamepadBindings` reports, on SDL's own mapping database and on generated bodies.

Model assumption: names are compared ASCII-case-insensitively. The C uses `SDL_strcasecmp`, which
also folds non-ASCII characters (e.g. U+212A KELVIN SIGN folds to `k`); the differential test only
uses ASCII bodies.
-/
namespace SDLVerif.Gamepad

/-! ## Bindings -/

inductive Input where
  | axis (axis : Nat) (min max : Int)
  | button (button : Nat)
  | hat (hat mask : Nat)
deriving DecidableEq, Repr

inductive Output where
  | axis (axis : Nat) (min max : Int)
  | button (button : Nat)
deriving DecidableEq, Repr

structure Binding where
  input : Input
  output : Output
deriving DecidableEq, Repr

def AXIS_MIN : Int := -32768
def AXIS_MAX : Int := 32767
def INT_MAX : Nat := 2147483647

/-! ## Names -/

def axisNames : List String := ["leftx", "lefty", "rightx", "righty", "lefttrigger", "righttrigger"]

def buttonNames : List String :=
  ["a", "b", "x", "y", "back", "guide", "start", "leftstick", "rightstick", "leftshoulder",
   "rightshoulder", "dpup", "dpdown", "dpleft", "dpright", "misc1", "paddle1", "paddle2", "paddle3",
   "paddle4", "touchpad", "misc2", "misc3", "misc4", "misc5", "misc6"]

def lower (c : Char) : Char := if 'A' ≤ c ∧ c ≤ 'Z' then Char.ofNat (c.toNat + 32) else c

/-- `SDL_strcasecmp(s, name) == 0` for ASCII. -/
def ieq (s : List Char) (name : String) : Bool := s.map lower == name.toList

def indexOf? (s : List Char) : List String → Nat → Option Nat
  | [], _ => none
  | n :: ns, k => if ieq s n then some k else indexOf? s ns (k + 1)

/-- `SDL_GetGamepadAxisFromString`: empty is invalid; one leading `+`/`-` is skipped. -/
def axisFromString : List Char → Option Nat
  | [] => none
  | c :: rest => indexOf? (if c = '+' ∨ c = '-' then rest else c :: rest) axisNames 0

/-- `SDL_PrivateGetGamepadButtonFromString`, with the GameCube (`axby`) and button-label
(`baxy`) face swaps. SOUTH=0, EAST=1, WEST=2, NORTH=3. -/
def buttonFromString (s : List Char) (axby baxy : Bool) : Option Nat :=
  if s = [] then none else
  (indexOf? s buttonNames 0).map fun i =>
    if axby then (if i = 1 then 2 else if i = 2 then 1 else i)
    else if baxy then (if i = 0 then 1 else if i = 1 then 0 else if i = 2 then 3 else if i = 3 then 2 else i)
    else i

/-! ## Numbers -/

def isDigit (c : Char) : Bool := '0' ≤ c ∧ c ≤ '9'

/-- `SDL_PrivateParseJoystickIndex`: at least one digit, stop at the first non-digit, reject a
value above `INT_MAX` (F-022). -/
def parseIndexAux : List Char → Nat → Option Nat
  | [], acc => some acc
  | c :: rest, acc =>
    if isDigit c then
      let v := acc * 10 + (c.toNat - '0'.toNat)
      if v > INT_MAX then none else parseIndexAux rest v
    else some acc

def parseIndex : List Char → Option Nat
  | [] => none
  | c :: rest => if isDigit c then parseIndexAux (c :: rest) 0 else none

/-! ## `SDL_PrivateParseGamepadElement` -/

/-- `game` and `joy` are the two C strings (the buffers up to their NUL). -/
def parseElement (game joy : List Char) (axby baxy : Bool) : Option Binding :=
  -- if (*szGameButton == '+' || *szGameButton == '-') half_axis_output = *szGameButton++;
  let (half_out, game) := match game with
    | c :: rest => if c = '+' ∨ c = '-' then (some c, rest) else (none, game)
    | [] => (none, game)
  let output : Option Output :=
    match axisFromString game with
    | some a =>
      if a = 4 ∨ a = 5 then some (.axis a 0 AXIS_MAX)
      else if half_out = some '+' then some (.axis a 0 AXIS_MAX)
      else if half_out = some '-' then some (.axis a 0 AXIS_MIN)
      else some (.axis a AXIS_MIN AXIS_MAX)
    | none => (buttonFromString game axby baxy).map .button
  match output with
  | none => none
  | some out =>
    let (half_in, joy) := match joy with
      | c :: rest => if c = '+' ∨ c = '-' then (some c, rest) else (none, joy)
      | [] => (none, joy)
    let invert := joy.getLast? = some '~'
    let input : Option Input :=
      match joy with
      | 'a' :: rest =>
        if rest.head?.map isDigit = some true then
          (parseIndex rest).map fun n =>
            let (lo, hi) := if half_in = some '+' then (0, AXIS_MAX)
              else if half_in = some '-' then (0, AXIS_MIN) else (AXIS_MIN, AXIS_MAX)
            if invert then .axis n hi lo else .axis n lo hi
        else none
      | 'b' :: rest =>
        if rest.head?.map isDigit = some true then (parseIndex rest).map .button else none
      | 'h' :: d :: '.' :: rest =>
        if isDigit d ∧ rest.head?.map isDigit = some true then
          (parseIndex rest).map fun m => .hat (d.toNat - '0'.toNat) m
        else none
      | _ => none
    input.map fun i => ⟨i, out⟩

/-! ## `SDL_PrivateParseGamepadConfigString` -/

def GAME_SIZE : Nat := 20
def JOY_SIZE : Nat := 128

/-- The C string held in a buffer: everything before the first NUL. -/
def cstr (buf : List Char) : List Char := buf.takeWhile (· ≠ '\x00')

def zeros (n : Nat) : List Char := List.replicate n '\x00'

structure St where
  inGame : Bool
  i : Nat
  game : List Char
  joy : List Char
  binds : List Binding
deriving Repr

def St.init : St := ⟨true, 0, zeros GAME_SIZE, zeros JOY_SIZE, []⟩

/-- Append a binding unless an equal one is already there (`SDL_memcmp` against the list). -/
def addBinding (bs : List Binding) (b : Binding) : List Binding :=
  if bs.contains b then bs else bs ++ [b]

def element (st : St) (axby baxy : Bool) : List Binding :=
  match parseElement (cstr st.game) (cstr st.joy) axby baxy with
  | some b => addBinding st.binds b
  | none => st.binds

/-- One character of the loop. `Sum.inl st` continues; `Sum.inr binds` is the "name too large"
early return (the bindings parsed so far are kept). -/
def stepC (axby baxy : Bool) (st : St) (c : Char) : St ⊕ List Binding :=
  if c = ':' then .inl { st with i := 0, inGame := false }
  else if c = ' ' then .inl st
  else if c = ',' then
    .inl ⟨true, 0, zeros GAME_SIZE, zeros JOY_SIZE, element st axby baxy⟩
  else if st.inGame then
    if st.i ≥ GAME_SIZE - 1 then .inr st.binds
    else .inl { st with game := st.game.set st.i c, i := st.i + 1 }
  else
    if st.i ≥ JOY_SIZE - 1 then .inr st.binds
    else .inl { st with joy := st.joy.set st.i c, i := st.i + 1 }

def loopC (axby baxy : Bool) : St → List Char → St ⊕ List Binding
  | st, [] => .inl st
  | st, c :: cs =>
    match stepC axby baxy st c with
    | .inl st' => loopC axby baxy st' cs
    | .inr bs => .inr bs

/-- `SDL_PrivateParseGamepadConfigString(gamepad, body)`: the bindings it leaves, and whether it
stopped early with "too large". `axby`/`baxy` are whether the whole mapping contains the
GameCube or button-label hint. The string ends at its first NUL. -/
def parseConfig (body : List Char) (axby baxy : Bool) : List Binding × Bool :=
  match loopC axby baxy St.init (cstr body) with
  | .inr bs => (bs, true)
  | .inl st =>
    if (cstr st.game).isEmpty ∧ (cstr st.joy).isEmpty then (st.binds, false)
    else (element st axby baxy, false)

/-! ## The loop, compositionally -/

theorem loopC_append (axby baxy : Bool) (st : St) (xs ys : List Char) :
    loopC axby baxy st (xs ++ ys) =
      match loopC axby baxy st xs with
      | .inl st' => loopC axby baxy st' ys
      | .inr bs => .inr bs := by
  induction xs generalizing st with
  | nil => rfl
  | cons c cs ih =>
    simp only [List.cons_append, loopC]
    cases stepC axby baxy st c with
    | inl st' => exact ih st'
    | inr bs => rfl

/-- **Spaces are ignored** anywhere in a mapping body. -/
theorem loopC_spaces (axby baxy : Bool) (st : St) (cs : List Char) :
    loopC axby baxy st (cs.filter (· ≠ ' ')) = loopC axby baxy st cs := by
  induction cs generalizing st with
  | nil => rfl
  | cons c cs ih =>
    by_cases hc : c = ' '
    · subst hc
      have hf : List.filter (fun x => decide (x ≠ ' ')) (' ' :: cs) =
          List.filter (fun x => decide (x ≠ ' ')) cs := by simp
      rw [hf, ih]
      simp [loopC, stepC]
    · simp only [List.filter_cons, ne_eq, hc, not_false_eq_true, decide_true, ite_true, loopC]
      cases stepC axby baxy st c with
      | inl st' => exact ih st'
      | inr bs => rfl

/-! ## The buffers stay terminated (F-006)

The C writes `szGameButton[i]` only when `i < sizeof - 1`, so the last byte of each buffer is
never written and stays `'\0'`: `SDL_strlen` on either buffer stops inside it. -/

/-- Both buffers have their C sizes and end in NUL. -/
def St.ok (st : St) : Prop :=
  st.game.length = GAME_SIZE ∧ st.joy.length = JOY_SIZE ∧
  st.game[GAME_SIZE - 1]? = some '\x00' ∧ st.joy[JOY_SIZE - 1]? = some '\x00'

theorem init_ok : St.init.ok := by
  simp [St.ok, St.init, zeros, GAME_SIZE, JOY_SIZE]

theorem stepC_ok (axby baxy : Bool) (st : St) (c : Char) (h : st.ok) :
    ∀ st', stepC axby baxy st c = .inl st' → st'.ok := by
  intro st' hs
  obtain ⟨hg, hj, hgl, hjl⟩ := h
  simp only [stepC] at hs
  split at hs
  · cases hs; exact ⟨hg, hj, hgl, hjl⟩
  · split at hs
    · cases hs; exact ⟨hg, hj, hgl, hjl⟩
    · split at hs
      · cases hs; simp [St.ok, zeros, GAME_SIZE, JOY_SIZE]
      · split at hs
        · split at hs
          · cases hs
          · cases hs
            refine ⟨by simp [hg], hj, ?_, hjl⟩
            simp only [List.getElem?_set]
            split <;> simp_all [GAME_SIZE] <;> omega
        · split at hs
          · cases hs
          · cases hs
            refine ⟨hg, by simp [hj], hgl, ?_⟩
            simp only [List.getElem?_set]
            split <;> simp_all [JOY_SIZE] <;> omega

theorem loopC_ok (axby baxy : Bool) (st : St) (cs : List Char) (h : st.ok) :
    ∀ st', loopC axby baxy st cs = .inl st' → st'.ok := by
  induction cs generalizing st with
  | nil => intro st' hs; cases hs; exact h
  | cons c cs ih =>
    intro st' hs
    simp only [loopC] at hs
    cases hst : stepC axby baxy st c with
    | inl s1 => rw [hst] at hs; exact ih s1 (stepC_ok axby baxy st c h s1 hst) st' hs
    | inr bs => rw [hst] at hs; cases hs

/-- A NUL at index `k` bounds the C string to `k` characters. -/
theorem cstr_le_nul (buf : List Char) (k : Nat) (h : buf[k]? = some '\x00') :
    (cstr buf).length ≤ k := by
  unfold cstr
  induction buf generalizing k with
  | nil => simp at h
  | cons c cs ih =>
    cases k with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at h
      simp [List.takeWhile_cons, h]
    | succ k =>
      simp only [List.getElem?_cons_succ] at h
      simp only [List.takeWhile_cons]
      split
      · simp only [List.length_cons]; have := ih k h; omega
      · simp

/-- So in a state that is `ok`, `SDL_strlen` on either buffer stops inside it: the C strings
are at most 19 and 127 characters. -/
theorem cstr_bounded (st : St) (h : st.ok) :
    (cstr st.game).length ≤ GAME_SIZE - 1 ∧ (cstr st.joy).length ≤ JOY_SIZE - 1 :=
  ⟨cstr_le_nul _ _ h.2.2.1, cstr_le_nul _ _ h.2.2.2⟩

/-- **The F-006 bound**: from the initial state, every state the loop reaches keeps both
buffers NUL-terminated, so the element parser only ever sees C strings that end inside their
buffers. -/
theorem parse_buffers_bounded (axby baxy : Bool) (cs : List Char) (st : St)
    (h : loopC axby baxy St.init cs = .inl st) :
    (cstr st.game).length ≤ GAME_SIZE - 1 ∧ (cstr st.joy).length ≤ JOY_SIZE - 1 :=
  cstr_bounded st (loopC_ok axby baxy St.init cs init_ok st h)

/-! ## The grammar

A well-formed element is `name:binding` where neither part contains `:`, `,`, a space or NUL,
and the parts fit their buffers (at most 19 and 127 characters). A body of well-formed elements,
each followed by `,`, parses to exactly the bindings `parseElement` gives each element, in order,
without duplicates. This is the specification that `SDL_PrivateParseGamepadConfigString`'s
character loop implements. -/

def plain (s : List Char) : Prop := ∀ c ∈ s, c ≠ ':' ∧ c ≠ ',' ∧ c ≠ ' ' ∧ c ≠ '\x00'

structure Elem where
  name : List Char
  bind : List Char

def Elem.wf (e : Elem) : Prop :=
  plain e.name ∧ plain e.bind ∧ e.name.length ≤ GAME_SIZE - 1 ∧ e.bind.length ≤ JOY_SIZE - 1

def body (es : List Elem) : List Char := es.flatMap fun e => e.name ++ ':' :: e.bind ++ [',']

def addOpt (bs : List Binding) : Option Binding → List Binding
  | some b => addBinding bs b
  | none => bs

/-- What the grammar says the bindings are. -/
def specBinds (axby baxy : Bool) (bs : List Binding) : List Elem → List Binding
  | [] => bs
  | e :: es => specBinds axby baxy (addOpt bs (parseElement e.name e.bind axby baxy)) es

/-- The loop state between elements. -/
def R (bs : List Binding) : St := ⟨true, 0, zeros GAME_SIZE, zeros JOY_SIZE, bs⟩

theorem set_at_length {α} (w t : List α) (a b : α) : (w ++ a :: t).set w.length b = w ++ b :: t := by
  induction w with
  | nil => rfl
  | cons x xs ih => simp [ih]

theorem zeros_succ (n : Nat) : zeros (n + 1) = '\x00' :: zeros n := rfl

theorem cstr_plain (w : List Char) (k : Nat) (hw : plain w) (hk : 0 < k) :
    cstr (w ++ zeros k) = w := by
  unfold cstr
  induction w with
  | nil =>
    obtain ⟨k', rfl⟩ : ∃ k', k = k' + 1 := ⟨k - 1, by omega⟩
    simp [zeros_succ]
  | cons c cs ih =>
    have hc := (hw c (List.mem_cons_self ..)).2.2.2
    have hcs : plain cs := fun x hx => hw x (List.mem_cons_of_mem _ hx)
    rw [List.cons_append, List.takeWhile_cons_of_pos (by simpa using hc), ih hcs]

/-- Characters of a name, written into the game buffer. -/
theorem fill_game (axby baxy : Bool) (g w joy : List Char) (bs : List Binding)
    (hg : plain g) (hlen : w.length + g.length ≤ GAME_SIZE - 1) :
    loopC axby baxy ⟨true, w.length, w ++ zeros (GAME_SIZE - w.length), joy, bs⟩ g =
      .inl ⟨true, (w ++ g).length, (w ++ g) ++ zeros (GAME_SIZE - (w ++ g).length), joy, bs⟩ := by
  induction g generalizing w with
  | nil => simp [loopC]
  | cons c cs ih =>
    have hc := hg c (List.mem_cons_self ..)
    have hcs : plain cs := fun x hx => hg x (List.mem_cons_of_mem _ hx)
    simp only [List.length_cons] at hlen
    have hstep : stepC axby baxy ⟨true, w.length, w ++ zeros (GAME_SIZE - w.length), joy, bs⟩ c =
        .inl ⟨true, (w ++ [c]).length, (w ++ [c]) ++ zeros (GAME_SIZE - (w ++ [c]).length), joy, bs⟩ := by
      obtain ⟨k, hk⟩ : ∃ k, GAME_SIZE - w.length = k + 1 := ⟨GAME_SIZE - w.length - 1, by simp [GAME_SIZE] at *; omega⟩
      have hk' : GAME_SIZE - (w.length + 1) = k := by simp [GAME_SIZE] at *; omega
      simp only [stepC, hc.1, hc.2.1, hc.2.2.1, if_false, ite_true]
      have hlt : ¬ w.length ≥ GAME_SIZE - 1 := by simp [GAME_SIZE] at *; omega
      simp only [hlt, ite_false, hk, hk', zeros_succ, set_at_length, List.length_append,
        List.length_singleton, List.append_assoc, List.singleton_append]
    simp only [loopC, hstep]
    have := ih (w ++ [c]) hcs (by simp; omega)
    simpa [List.append_assoc] using this

/-- Characters of a binding, written into the joystick buffer. -/
theorem fill_joy (axby baxy : Bool) (j w game : List Char) (bs : List Binding)
    (hj : plain j) (hlen : w.length + j.length ≤ JOY_SIZE - 1) :
    loopC axby baxy ⟨false, w.length, game, w ++ zeros (JOY_SIZE - w.length), bs⟩ j =
      .inl ⟨false, (w ++ j).length, game, (w ++ j) ++ zeros (JOY_SIZE - (w ++ j).length), bs⟩ := by
  induction j generalizing w with
  | nil => simp [loopC]
  | cons c cs ih =>
    have hc := hj c (List.mem_cons_self ..)
    have hcs : plain cs := fun x hx => hj x (List.mem_cons_of_mem _ hx)
    simp only [List.length_cons] at hlen
    have hstep : stepC axby baxy ⟨false, w.length, game, w ++ zeros (JOY_SIZE - w.length), bs⟩ c =
        .inl ⟨false, (w ++ [c]).length, game, (w ++ [c]) ++ zeros (JOY_SIZE - (w ++ [c]).length), bs⟩ := by
      obtain ⟨k, hk⟩ : ∃ k, JOY_SIZE - w.length = k + 1 := ⟨JOY_SIZE - w.length - 1, by simp [JOY_SIZE] at *; omega⟩
      have hk' : JOY_SIZE - (w.length + 1) = k := by simp [JOY_SIZE] at *; omega
      simp only [stepC, hc.1, hc.2.1, hc.2.2.1, ite_false, Bool.false_eq_true]
      have hlt : ¬ w.length ≥ JOY_SIZE - 1 := by simp [JOY_SIZE] at *; omega
      simp only [hlt, ite_false, hk, hk', zeros_succ, set_at_length, List.length_append,
        List.length_singleton, List.append_assoc, List.singleton_append]
    simp only [loopC, hstep]
    have := ih (w ++ [c]) hcs (by simp; omega)
    simpa [List.append_assoc] using this

/-- One well-formed element followed by `,`. -/
theorem loop_elem (axby baxy : Bool) (bs : List Binding) (e : Elem) (he : e.wf) :
    loopC axby baxy (R bs) (e.name ++ ':' :: e.bind ++ [',']) =
      .inl (R (addOpt bs (parseElement e.name e.bind axby baxy))) := by
  obtain ⟨hn, hb, hnl, hbl⟩ := he
  have h1 := fill_game axby baxy e.name [] (zeros JOY_SIZE) bs hn (by simpa using hnl)
  simp only [List.length_nil, List.nil_append, Nat.sub_zero] at h1
  have h2 := fill_joy axby baxy e.bind [] (e.name ++ zeros (GAME_SIZE - e.name.length)) bs hb
    (by simpa using hbl)
  simp only [List.length_nil, List.nil_append, Nat.sub_zero] at h2
  rw [show e.name ++ ':' :: e.bind ++ [','] = e.name ++ (':' :: (e.bind ++ [','])) by simp,
    loopC_append]
  simp only [R] at h1 ⊢
  rw [h1]
  simp only [loopC, stepC, ite_true]
  rw [loopC_append, h2]
  have hgk : 0 < GAME_SIZE - e.name.length := by simp [GAME_SIZE] at *; omega
  have hjk : 0 < JOY_SIZE - e.bind.length := by simp [JOY_SIZE] at *; omega
  simp [loopC, stepC, element, cstr_plain _ _ hn hgk, cstr_plain _ _ hb hjk, addOpt]

theorem takeWhile_all {α} (p : α → Bool) (l : List α) (h : ∀ c ∈ l, p c = true) :
    l.takeWhile p = l := by
  induction l with
  | nil => rfl
  | cons x xs ih =>
    rw [List.takeWhile_cons_of_pos (h x (List.mem_cons_self ..))]
    rw [ih (fun c hc => h c (List.mem_cons_of_mem _ hc))]

/-- **The grammar theorem.** -/
theorem parse_wellformed (axby baxy : Bool) (es : List Elem) (hes : ∀ e ∈ es, e.wf) :
    parseConfig (body es) axby baxy = (specBinds axby baxy [] es, false) := by
  have hloop : ∀ (bs : List Binding) (es : List Elem), (∀ e ∈ es, e.wf) →
      loopC axby baxy (R bs) (body es) = .inl (R (specBinds axby baxy bs es)) := by
    intro bs es hes
    induction es generalizing bs with
    | nil => rfl
    | cons e es ih =>
      simp only [body, List.flatMap_cons] at ih ⊢
      rw [loopC_append, loop_elem axby baxy bs e (hes e (List.mem_cons_self ..))]
      exact ih _ (fun x hx => hes x (List.mem_cons_of_mem _ hx))
  have hplain : cstr (body es) = body es := by
    unfold cstr
    apply takeWhile_all
    intro c hc
    simp only [body, List.mem_flatMap] at hc
    obtain ⟨e, hemem, hce⟩ := hc
    obtain ⟨hn, hb, -, -⟩ := hes e hemem
    simp only [List.mem_append, List.mem_cons] at hce
    rcases hce with (hce | hce | hce) | hce
    · simpa using (hn c hce).2.2.2
    · subst hce; decide
    · simpa using (hb c hce).2.2.2
    · rcases hce with hce | hce
      · subst hce; decide
      · cases hce
  simp only [parseConfig, hplain, St.init]
  rw [show (⟨true, 0, zeros GAME_SIZE, zeros JOY_SIZE, []⟩ : St) = R [] from rfl, hloop [] es hes]
  simp [R, cstr, zeros, GAME_SIZE, JOY_SIZE]

/-- The hints the element parser looks for in the whole mapping string. -/
def isInfix (needle hay : List Char) : Bool :=
  (List.range (hay.length + 1)).any fun k => (hay.drop k).take needle.length == needle

def axbyOf (mapping : List Char) : Bool :=
  isInfix ",hint:SDL_GAMECONTROLLER_USE_GAMECUBE_LABELS:=1".toList mapping
def baxyOf (mapping : List Char) : Bool :=
  isInfix ",hint:SDL_GAMECONTROLLER_USE_BUTTON_LABELS:=1".toList mapping

/-! ## Round trip of `SDL_GetGamepadMapping` (F-025)

`CreateMappingString` reports `guid,name,<stored body>`, appending `platform:<P>,` (after a `,` if
the body doesn't end in one) when the body has no `platform:` field. Since F-025 it no longer
cuts the report at a second `platform:`. -/

def platformName : List Char := "platform".toList
def platformField : List Char := platformName ++ [':']

/-- The body part of what the fixed `CreateMappingString` reports. -/
def reportBody (stored plat : List Char) : List Char :=
  if isInfix platformField stored then stored
  else stored ++ (if stored ≠ [] ∧ stored.getLast? ≠ some ',' then [','] else []) ++
    (platformField ++ plat ++ [','])

/-- The pre-fix report: cut at the second `platform:`. -/
def cutAtSecondPlatform (s : List Char) : List Char :=
  let firstEnd := (List.range s.length).find? fun k => (s.drop k).take 9 == platformField
  match firstEnd with
  | none => s
  | some k =>
    match (List.range s.length).find? fun m => k < m ∧ (s.drop m).take 9 == platformField with
    | none => s
    | some m => s.take m

theorem platform_elem_none (plat : List Char) (axby baxy : Bool) :
    parseElement platformName plat axby baxy = none := by
  rfl

theorem platformName_plain : plain platformName := by
  intro c hc
  simp only [platformName] at hc
  revert c
  decide

theorem loop_R_after_comma (axby baxy : Bool) (xs : List Char) :
    ∀ st, loopC axby baxy St.init (xs ++ [',']) = .inl st → ∃ bs, st = R bs := by
  intro st h
  rw [loopC_append] at h
  cases hx : loopC axby baxy St.init xs with
  | inr bs => rw [hx] at h; cases h
  | inl st0 =>
    rw [hx] at h
    have hc : stepC axby baxy st0 ',' = .inl (R (element st0 axby baxy)) := by
      simp [stepC, R]
    simp only [loopC, hc] at h
    cases h; exact ⟨_, rfl⟩

/-- What `parseConfig` does at the end of input. -/
def finish (st : St) (axby baxy : Bool) : List Binding :=
  if (cstr st.game).isEmpty ∧ (cstr st.joy).isEmpty then st.binds else element st axby baxy

/-- The final flush is the same as a `,`: an element with an empty name yields no binding. -/
theorem finish_eq_element (st : St) (axby baxy : Bool) : finish st axby baxy = element st axby baxy := by
  unfold finish element
  split
  · rename_i h
    have hg : cstr st.game = [] := by simpa using h.1
    simp [hg, parseElement, axisFromString, buttonFromString]
  · rfl

theorem finish_R (bs : List Binding) (axby baxy : Bool) : finish (R bs) axby baxy = bs := by
  simp [finish, R, cstr, zeros, GAME_SIZE, JOY_SIZE]

theorem parseConfig_eq (body : List Char) (axby baxy : Bool) :
    (parseConfig body axby baxy).1 =
      match loopC axby baxy St.init (cstr body) with
      | .inr bs => bs
      | .inl st => finish st axby baxy := by
  unfold parseConfig finish
  cases loopC axby baxy St.init (cstr body) with
  | inr bs => rfl
  | inl st => exact apply_ite Prod.fst _ _ _

/-- **Round trip.** For a stored body without NUL and a short platform name, the bindings of the
reported mapping are those of the stored one. (The face-label flags are taken as given: they
come from searching the body for a hint ending in `=1`, and the appended text starts with `,`
or `platform:`.) -/
theorem report_roundtrip (axby baxy : Bool) (stored plat : List Char)
    (hs : ∀ c ∈ stored, c ≠ '\x00') (hp : plain plat) (hpl : plat.length ≤ JOY_SIZE - 1) :
    (parseConfig (reportBody stored plat) axby baxy).1 = (parseConfig stored axby baxy).1 := by
  unfold reportBody
  split
  · rfl
  have he : (⟨platformName, plat⟩ : Elem).wf :=
    ⟨platformName_plain, hp, (by show platformName.length ≤ GAME_SIZE - 1; decide), hpl⟩
  have hnone := platform_elem_none plat axby baxy
  have hplat : ∀ bs, loopC axby baxy (R bs) (platformField ++ plat ++ [',']) = .inl (R bs) := by
    intro bs
    have hb : platformField ++ plat ++ [','] = platformName ++ ':' :: plat ++ [','] := by
      simp [platformField]
    rw [hb, loop_elem axby baxy bs ⟨platformName, plat⟩ he]
    simp [hnone, addOpt]
  have hcs : ∀ xs, (∀ c ∈ xs, c ≠ '\x00') → cstr xs = xs := fun xs h =>
    takeWhile_all _ _ (fun c hc => by simpa using h c hc)
  have hsuf : ∀ c ∈ platformField ++ plat ++ [','], c ≠ '\x00' := by
    intro c hc
    simp only [platformField, List.mem_append, List.mem_singleton] at hc
    rcases hc with ((hc | hc) | hc) | hc
    · exact (platformName_plain c hc).2.2.2
    · subst hc; decide
    · exact (hp c hc).2.2.2
    · subst hc; decide
  rw [parseConfig_eq, parseConfig_eq, hcs _ hs]
  by_cases hsep : stored ≠ [] ∧ stored.getLast? ≠ some ','
  · -- a ',' goes in first: it flushes the pending element, as the end of input would
    rw [if_pos hsep, List.append_assoc]
    have hall : ∀ c ∈ stored ++ ([','] ++ (platformField ++ plat ++ [','])), c ≠ '\x00' := by
      intro c hc
      rcases List.mem_append.mp hc with hc | hc
      · exact hs c hc
      · rcases List.mem_append.mp hc with hc | hc
        · simp at hc; subst hc; decide
        · exact hsuf c hc
    rw [hcs _ hall, loopC_append]
    cases hl : loopC axby baxy St.init stored with
    | inr bs => rfl
    | inl st =>
      have hc : stepC axby baxy st ',' = .inl (R (element st axby baxy)) := by simp [stepC, R]
      simp only [List.singleton_append, loopC, hc, hplat]
      rw [finish_R, finish_eq_element]
  · -- the body is empty or already ends in ',': the loop is between elements there
    rw [if_neg hsep, List.append_nil]
    have hall : ∀ c ∈ stored ++ (platformField ++ plat ++ [',']), c ≠ '\x00' := by
      intro c hc
      rcases List.mem_append.mp hc with hc | hc
      · exact hs c hc
      · exact hsuf c hc
    rw [hcs _ hall, loopC_append]
    have hR : ∀ st, loopC axby baxy St.init stored = .inl st → ∃ bs, st = R bs := by
      intro st hl
      rcases List.eq_nil_or_concat stored with hemp | ⟨init, b, hib⟩
      · subst hemp; simp only [loopC] at hl; cases hl; exact ⟨[], rfl⟩
      · rw [List.concat_eq_append] at hib
        subst hib
        have hb : b = ',' := by
          have : (init ++ [b]).getLast? ≠ some ',' → False := fun h => hsep ⟨by simp, h⟩
          exact Classical.byContradiction fun hne => this (by simp [hne])
        subst hb
        exact loop_R_after_comma axby baxy init st hl
    cases hl : loopC axby baxy St.init stored with
    | inr bs => rfl
    | inl st =>
      obtain ⟨bs, rfl⟩ := hR st hl
      simp only [hplat, finish_R]

/-- The record of F-025: with the old report, a mapping with two `platform:` fields does not
round-trip. `x:b1,platform:A,platform:B,y:b2,` has two bindings; the old report
`x:b1,platform:A,` has one. -/
theorem prefix_report_loses_bindings :
    (parseConfig "x:b1,platform:A,platform:B,y:b2,".toList false false).1.length = 2 ∧
    (parseConfig (cutAtSecondPlatform "x:b1,platform:A,platform:B,y:b2,".toList) false false).1.length = 1 := by
  decide

end SDLVerif.Gamepad
