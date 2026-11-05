---------------------------- MODULE InitState ----------------------------
(***************************************************************************)
(* Model of SDL_InitState: SDL_ShouldInit / SDL_ShouldQuit /              *)
(* SDL_SetInitialized, src/thread/SDL_thread.c:556-594 (commit cb6224d2e). *)
(*                                                                         *)
(* Each step below is one atomic operation in the C code:                  *)
(*   - SDL_GetAtomicInt (the while-loop condition)          -> *_read      *)
(*   - SDL_CompareAndSwapAtomicInt                          -> *_cas       *)
(*   - the plain store `state->thread = SDL_GetCurrentThreadID()`          *)
(*                                                          -> *_setthread *)
(*   - SDL_SetInitialized (asserts state->thread == self, then             *)
(*     SDL_SetAtomicInt)                                    -> *_body      *)
(* SDL_Delay(1) after a failed CAS is a stutter; it is modelled as going   *)
(* back to the read.                                                       *)
(*                                                                         *)
(* Clients follow the contract documented in include/SDL3/SDL_mutex.h:     *)
(* a thread that gets `true` from ShouldInit/ShouldQuit calls              *)
(* SDL_SetInitialized exactly once before doing anything else with this    *)
(* state (no re-entrant calls by the owner). Init may fail                 *)
(* (SetInitialized(false)), which also covers the doc's "UseSubsystem"     *)
(* pattern.                                                                *)
(*                                                                         *)
(* Assumes sequentially consistent interleaving; SDL's atomics are         *)
(* sequentially consistent (full barriers) on all supported backends.      *)
(*                                                                         *)
(* MUTANT selects a deliberately broken variant so each property is shown *)
(* to be able to fail. "none" is the real code.                            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Threads, MaxOps, MUTANT

ASSUME MUTANT \in {"none",
                   "check_then_act",   \* CAS replaced by a separate read and a write
                   "thread_before_cas",\* state->thread written before the CAS
                   "quit_from_initializing", \* ShouldQuit CASes from INITIALIZING
                   "fail_without_set"} \* owner's failed init never calls SetInitialized

UNINIT == "UNINITIALIZED"
INITING == "INITIALIZING"
INITED == "INITIALIZED"
UNINITING == "UNINITIALIZING"
Status == {UNINIT, INITING, INITED, UNINITING}

NoThread == "none"

VARIABLES
    status,     \* state->status (SDL_AtomicInt)
    owner,      \* state->thread (plain, non-atomic field)
    pc,         \* per-thread program counter
    ops,        \* number of operations each thread has started (bounds the model)
    result      \* last return value of ShouldInit/ShouldQuit per thread

vars == <<status, owner, pc, ops, result>>

PCs == {"idle",
        "si_read", "si_cas", "si_write", "si_setthread", "init_body",
        "sq_read", "sq_cas", "sq_write", "sq_setthread", "quit_body"}

TypeOK ==
    /\ status \in Status
    /\ owner \in Threads \cup {NoThread}
    /\ pc \in [Threads -> PCs]
    /\ ops \in [Threads -> 0..MaxOps]
    /\ result \in [Threads -> BOOLEAN]

Init ==
    /\ status = UNINIT          \* static SDL_InitState is zero-initialized
    /\ owner = NoThread
    /\ pc = [t \in Threads |-> "idle"]
    /\ ops = [t \in Threads |-> 0]
    /\ result = [t \in Threads |-> FALSE]

Goto(t, l) == pc' = [pc EXCEPT ![t] = l]
Return(t, r) == /\ pc' = [pc EXCEPT ![t] = "idle"]
                /\ result' = [result EXCEPT ![t] = r]

\* A client starts a call to InitSystem() or QuitSystem().
Start(t) ==
    /\ pc[t] = "idle"
    /\ ops[t] < MaxOps
    /\ ops' = [ops EXCEPT ![t] = @ + 1]
    /\ \E entry \in {"si_read", "sq_read"} :
         IF MUTANT = "thread_before_cas"
         THEN /\ Goto(t, IF entry = "si_read" THEN "si_setthread" ELSE "sq_setthread")
         ELSE Goto(t, entry)
    /\ UNCHANGED <<status, owner, result>>

(* ---------------- SDL_ShouldInit ---------------- *)
\* while (SDL_GetAtomicInt(&state->status) != SDL_INIT_STATUS_INITIALIZED)
SiRead(t) ==
    /\ pc[t] = "si_read"
    /\ IF status = INITED
       THEN Return(t, FALSE)
       ELSE /\ Goto(t, "si_cas")
            /\ UNCHANGED result
    /\ UNCHANGED <<status, owner, ops>>

\* if (SDL_CompareAndSwapAtomicInt(&status, UNINITIALIZED, INITIALIZING))
SiCas(t) ==
    /\ pc[t] = "si_cas"
    /\ IF MUTANT = "check_then_act"
       THEN /\ Goto(t, IF status = UNINIT THEN "si_write" ELSE "si_read")
            /\ UNCHANGED status
       ELSE IF status = UNINIT
            THEN /\ status' = INITING
                 /\ Goto(t, IF MUTANT = "thread_before_cas" THEN "init_body" ELSE "si_setthread")
            ELSE /\ Goto(t, "si_read")          \* SDL_Delay(1); loop
                 /\ UNCHANGED status
    /\ UNCHANGED <<owner, ops, result>>

\* Second half of the non-atomic check-then-act mutant.
SiWrite(t) ==
    /\ pc[t] = "si_write"
    /\ status' = INITING
    /\ Goto(t, "si_setthread")
    /\ UNCHANGED <<owner, ops, result>>

\* state->thread = SDL_GetCurrentThreadID(); return true;
SiSetThread(t) ==
    /\ pc[t] = "si_setthread"
    /\ owner' = t
    /\ Goto(t, IF MUTANT = "thread_before_cas" THEN "si_read" ELSE "init_body")
    /\ UNCHANGED <<status, ops, result>>

\* DoInitTasks(); SDL_SetInitialized(&init, ok);
InitBody(t) ==
    /\ pc[t] = "init_body"
    /\ \E ok \in BOOLEAN :
         IF MUTANT = "fail_without_set" /\ ~ok
         THEN UNCHANGED status                  \* returns without SetInitialized
         ELSE status' = IF ok THEN INITED ELSE UNINIT
    /\ Return(t, TRUE)
    /\ UNCHANGED <<owner, ops>>

(* ---------------- SDL_ShouldQuit ---------------- *)
SqRead(t) ==
    /\ pc[t] = "sq_read"
    /\ IF status = UNINIT
       THEN Return(t, FALSE)
       ELSE /\ Goto(t, "sq_cas")
            /\ UNCHANGED result
    /\ UNCHANGED <<status, owner, ops>>

SqCas(t) ==
    /\ pc[t] = "sq_cas"
    /\ LET from == IF MUTANT = "quit_from_initializing" THEN {INITED, INITING} ELSE {INITED}
       IN IF MUTANT = "check_then_act"
          THEN /\ Goto(t, IF status \in from THEN "sq_write" ELSE "sq_read")
               /\ UNCHANGED status
          ELSE IF status \in from
               THEN /\ status' = UNINITING
                    /\ Goto(t, IF MUTANT = "thread_before_cas" THEN "quit_body" ELSE "sq_setthread")
               ELSE /\ Goto(t, "sq_read")
                    /\ UNCHANGED status
    /\ UNCHANGED <<owner, ops, result>>

SqWrite(t) ==
    /\ pc[t] = "sq_write"
    /\ status' = UNINITING
    /\ Goto(t, "sq_setthread")
    /\ UNCHANGED <<owner, ops, result>>

SqSetThread(t) ==
    /\ pc[t] = "sq_setthread"
    /\ owner' = t
    /\ Goto(t, IF MUTANT = "thread_before_cas" THEN "sq_read" ELSE "quit_body")
    /\ UNCHANGED <<status, ops, result>>

\* DoQuitTasks(); SDL_SetInitialized(&init, false);
QuitBody(t) ==
    /\ pc[t] = "quit_body"
    /\ status' = UNINIT
    /\ Return(t, TRUE)
    /\ UNCHANGED <<owner, ops>>

Step(t) ==
    \/ Start(t)
    \/ SiRead(t) \/ SiCas(t) \/ SiWrite(t) \/ SiSetThread(t) \/ InitBody(t)
    \/ SqRead(t) \/ SqCas(t) \/ SqWrite(t) \/ SqSetThread(t) \/ QuitBody(t)

\* Every thread has used up its operations: stutter instead of deadlocking,
\* so TLC's deadlock check only reports genuinely stuck states.
Finished ==
    /\ \A t \in Threads : pc[t] = "idle" /\ ops[t] = MaxOps
    /\ UNCHANGED vars

Next == (\E t \in Threads : Step(t)) \/ Finished

Spec == Init /\ [][Next]_vars /\ \A t \in Threads : WF_vars(Step(t))

-----------------------------------------------------------------------------
(* Properties *)

InitOwnerPCs == {"init_body"}
QuitOwnerPCs == {"quit_body"}
OwnerPCs == InitOwnerPCs \cup QuitOwnerPCs

\* At most one thread is inside an init or quit body at a time.
MutualExclusion ==
    Cardinality({t \in Threads : pc[t] \in OwnerPCs}) <= 1

\* An init body only runs while status is INITIALIZING, a quit body only
\* while status is UNINITIALIZING (so init and quit never overlap).
OwnerMatchesStatus ==
    \A t \in Threads :
        /\ pc[t] \in InitOwnerPCs => status = INITING
        /\ pc[t] \in QuitOwnerPCs => status = UNINITING

\* The SDL_assert in SDL_SetInitialized holds: when the owner calls it,
\* state->thread is the owner.
SetInitializedAssert ==
    \A t \in Threads : pc[t] \in OwnerPCs => owner = t

\* No transitional status without a thread that will finish the transition.
TransitionHasOwner ==
    status \in {INITING, UNINITING} =>
        \E t \in Threads : pc[t] \in OwnerPCs \cup {"si_setthread", "sq_setthread"}

\* Every call returns (no thread spins forever), given the bounded number of
\* operations per thread.
Termination == \A t \in Threads : pc[t] # "idle" ~> pc[t] = "idle"

=============================================================================
