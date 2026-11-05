---------------------------- MODULE GenericCond ----------------------------
(***************************************************************************)
(* Model of SDL's semaphore-based condition variable,                      *)
(* src/thread/generic/SDL_syscond.c (commit cb6224d2e), together with a    *)
(* client that uses it the documented way.                                 *)
(*                                                                         *)
(* Where this code runs: Vita, PSP, PS2, 3DS and DOS (CMakeLists.txt), and *)
(* Windows when the native condition-variable API is unavailable           *)
(* (src/thread/windows/SDL_syscond_cv.c:173). Not macOS: there the generic *)
(* *semaphore* is used, on top of pthread condition variables.             *)
(*                                                                         *)
(* The three internal SDL_Semaphores (sem, handshake_sem, signal_sem) are  *)
(* modelled as atomic counting semaphores; on the platforms above they are *)
(* native kernel semaphores. num_waiting / num_signals are only touched    *)
(* while holding signal_sem, so each critical section's body is merged     *)
(* with its acquire; releases are separate steps.                          *)
(*                                                                         *)
(* Client (CLIENT constant):                                               *)
(*   "tickets": each producer adds one ticket and calls Signal or Broadcast*)
(*              (either inside or after its critical section); each        *)
(*              consumer waits until a ticket exists and takes one.        *)
(*   "flag":    producers set a flag and Broadcast; consumers wait for it. *)
(* Consumers wait in the canonical loop: lock; while (!pred) wait; unlock. *)
(* TIMEOUTS = TRUE lets every semaphore wait in SDL_WaitConditionTimeoutNS *)
(* time out at any moment.                                                 *)
(*                                                                         *)
(* Fairness: strong fairness per thread, i.e. the scheduler, the user      *)
(* mutex and the semaphores are fair.                                      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Consumers, Producers, CLIENT, TIMEOUTS, MUTANT

ASSUME CLIENT \in {"tickets", "flag"}
ASSUME TIMEOUTS \in BOOLEAN
ASSUME MUTANT \in {"none",
                   "unlock_before_register", \* waiter drops the user mutex before num_waiting++
                   "no_count_check",         \* Signal posts even when no unsignalled waiter exists
                   "broadcast_one",          \* Broadcast releases only one waiter
                   "no_handshake_ack"}       \* woken waiter never posts handshake_sem

Threads == Consumers \cup Producers
None == "none"

VARIABLES
    m,          \* user mutex: owning thread or None
    ss,         \* cond->signal_sem count (starts at 1: it is a lock)
    sem,        \* cond->sem count
    hs,         \* cond->handshake_sem count
    nw,         \* cond->num_waiting
    ns,         \* cond->num_signals
    pc,
    tickets,    \* client state ("tickets")
    flag,       \* client state ("flag")
    opDone,     \* producer has finished its Signal/Broadcast
    kp, kh,     \* Broadcast's loop counters: posts left, handshakes left
    sigs        \* number of Signal/Broadcast calls that released a waiter

vars == <<m, ss, sem, hs, nw, ns, pc, tickets, flag, opDone, kp, kh, sigs>>

N == Cardinality(Consumers)

Init ==
    /\ m = None
    /\ ss = 1 /\ sem = 0 /\ hs = 0
    /\ nw = 0 /\ ns = 0
    /\ pc = [t \in Threads |-> IF t \in Consumers THEN "w_lock" ELSE "p_lock"]
    /\ tickets = 0
    /\ flag = FALSE
    /\ opDone = [t \in Producers |-> FALSE]
    /\ kp = [t \in Producers |-> 0]
    /\ kh = [t \in Producers |-> 0]
    /\ sigs = 0

Goto(t, l) == pc' = [pc EXCEPT ![t] = l]

Pred == IF CLIENT = "tickets" THEN tickets > 0 ELSE flag

-----------------------------------------------------------------------------
(* Consumer *)

WLock(t) ==                                         \* SDL_LockMutex(lock)
    /\ pc[t] = "w_lock" /\ m = None
    /\ m' = t /\ Goto(t, "w_check")
    /\ UNCHANGED <<ss, sem, hs, nw, ns, tickets, flag, opDone, kp, kh, sigs>>

WCheck(t) ==                                        \* while (!pred) wait
    /\ pc[t] = "w_check"
    /\ IF Pred
       THEN /\ tickets' = IF CLIENT = "tickets" THEN tickets - 1 ELSE tickets
            /\ Goto(t, "w_unlock")
       ELSE /\ Goto(t, IF MUTANT = "unlock_before_register" THEN "c_unlock" ELSE "c_acq")
            /\ UNCHANGED tickets
    /\ UNCHANGED <<m, ss, sem, hs, nw, ns, flag, opDone, kp, kh, sigs>>

WUnlock(t) ==
    /\ pc[t] = "w_unlock"
    /\ m' = None /\ Goto(t, "w_done")
    /\ UNCHANGED <<ss, sem, hs, nw, ns, tickets, flag, opDone, kp, kh, sigs>>

\* SDL_WaitSemaphore(signal_sem); num_waiting++;
CAcq(t) ==
    /\ pc[t] = "c_acq" /\ ss > 0
    /\ ss' = ss - 1 /\ nw' = nw + 1
    /\ Goto(t, "c_rel")
    /\ UNCHANGED <<m, sem, hs, ns, tickets, flag, opDone, kp, kh, sigs>>

\* SDL_SignalSemaphore(signal_sem);
CRel(t) ==
    /\ pc[t] = "c_rel"
    /\ ss' = ss + 1
    /\ Goto(t, IF MUTANT = "unlock_before_register" THEN "c_wait" ELSE "c_unlock")
    /\ UNCHANGED <<m, sem, hs, nw, ns, tickets, flag, opDone, kp, kh, sigs>>

\* SDL_UnlockMutex(mutex);
CUnlock(t) ==
    /\ pc[t] = "c_unlock"
    /\ m' = None
    /\ Goto(t, IF MUTANT = "unlock_before_register" THEN "c_acq" ELSE "c_wait")
    /\ UNCHANGED <<ss, sem, hs, nw, ns, tickets, flag, opDone, kp, kh, sigs>>

\* result = SDL_WaitSemaphoreTimeoutNS(cond->sem, timeoutNS);
CWait(t) ==
    /\ pc[t] = "c_wait"
    /\ \/ /\ sem > 0 /\ sem' = sem - 1
       \/ /\ TIMEOUTS /\ UNCHANGED sem              \* timed out
    /\ Goto(t, "c_ack")
    /\ UNCHANGED <<m, ss, hs, nw, ns, tickets, flag, opDone, kp, kh, sigs>>

\* SDL_WaitSemaphore(signal_sem);
\* if (num_signals > 0) { SDL_SignalSemaphore(handshake_sem); num_signals--; }
\* num_waiting--;
CAck(t) ==
    /\ pc[t] = "c_ack" /\ ss > 0
    /\ ss' = ss - 1
    /\ IF ns > 0
       THEN /\ hs' = IF MUTANT = "no_handshake_ack" THEN hs ELSE hs + 1
            /\ ns' = ns - 1
       ELSE UNCHANGED <<hs, ns>>
    /\ nw' = nw - 1
    /\ Goto(t, "c_rel2")
    /\ UNCHANGED <<m, sem, tickets, flag, opDone, kp, kh, sigs>>

\* SDL_SignalSemaphore(signal_sem); then SDL_LockMutex(mutex) and re-check.
CRel2(t) ==
    /\ pc[t] = "c_rel2"
    /\ ss' = ss + 1
    /\ Goto(t, "w_lock")
    /\ UNCHANGED <<m, sem, hs, nw, ns, tickets, flag, opDone, kp, kh, sigs>>

Consumer(t) ==
    WLock(t) \/ WCheck(t) \/ WUnlock(t) \/ CAcq(t) \/ CRel(t) \/ CUnlock(t)
    \/ CWait(t) \/ CAck(t) \/ CRel2(t)

-----------------------------------------------------------------------------
(* Producer *)

PLock(t) ==
    /\ pc[t] = "p_lock" /\ m = None
    /\ m' = t /\ Goto(t, "p_update")
    /\ UNCHANGED <<ss, sem, hs, nw, ns, tickets, flag, opDone, kp, kh, sigs>>

\* Update the predicate, then either signal while still holding the mutex
\* or unlock first and signal afterwards. Both are allowed by the API.
PUpdate(t) ==
    /\ pc[t] = "p_update"
    /\ IF CLIENT = "tickets"
       THEN tickets' = tickets + 1 /\ UNCHANGED flag
       ELSE flag' = TRUE /\ UNCHANGED tickets
    /\ \E l \in IF CLIENT = "tickets" THEN {"s_acq", "b_acq", "p_unlock"} ELSE {"b_acq", "p_unlock"} :
         Goto(t, l)
    /\ UNCHANGED <<m, ss, sem, hs, nw, ns, opDone, kp, kh, sigs>>

\* After the critical section, a producer that hasn't signalled yet does so.
PUnlock(t) ==
    /\ pc[t] = "p_unlock"
    /\ m' = None
    /\ IF opDone[t]
       THEN Goto(t, "p_done")
       ELSE \E l \in IF CLIENT = "tickets" THEN {"s_acq", "b_acq"} ELSE {"b_acq"} : Goto(t, l)
    /\ UNCHANGED <<ss, sem, hs, nw, ns, tickets, flag, opDone, kp, kh, sigs>>

FinishOp(t) ==
    /\ opDone' = [opDone EXCEPT ![t] = TRUE]
    /\ Goto(t, IF m = t THEN "p_unlock" ELSE "p_done")

\* --- SDL_SignalCondition_generic ---
\* SDL_WaitSemaphore(signal_sem); if (num_waiting > num_signals) num_signals++;
SAcq(t) ==
    /\ pc[t] = "s_acq" /\ ss > 0
    /\ ss' = ss - 1
    /\ IF nw > ns \/ MUTANT = "no_count_check"
       THEN /\ ns' = ns + 1 /\ sigs' = sigs + 1
            /\ Goto(t, "s_post")
       ELSE /\ UNCHANGED <<ns, sigs>>
            /\ Goto(t, "s_rel_noop")
    /\ UNCHANGED <<m, sem, hs, nw, tickets, flag, opDone, kp, kh>>

SPost(t) ==                                         \* SDL_SignalSemaphore(sem)
    /\ pc[t] = "s_post"
    /\ sem' = sem + 1 /\ Goto(t, "s_rel")
    /\ UNCHANGED <<m, ss, hs, nw, ns, tickets, flag, opDone, kp, kh, sigs>>

SRel(t) ==                                          \* SDL_SignalSemaphore(signal_sem)
    /\ pc[t] = "s_rel"
    /\ ss' = ss + 1 /\ Goto(t, "s_hs")
    /\ UNCHANGED <<m, sem, hs, nw, ns, tickets, flag, opDone, kp, kh, sigs>>

SHs(t) ==                                           \* SDL_WaitSemaphore(handshake_sem)
    /\ pc[t] = "s_hs" /\ hs > 0
    /\ hs' = hs - 1
    /\ FinishOp(t)
    /\ UNCHANGED <<m, ss, sem, nw, ns, tickets, flag, kp, kh, sigs>>

SRelNoop(t) ==                                      \* else SDL_SignalSemaphore(signal_sem)
    /\ pc[t] = "s_rel_noop"
    /\ ss' = ss + 1
    /\ FinishOp(t)
    /\ UNCHANGED <<m, sem, hs, nw, ns, tickets, flag, kp, kh, sigs>>

\* --- SDL_BroadcastCondition_generic ---
BAcq(t) ==
    /\ pc[t] = "b_acq" /\ ss > 0
    /\ ss' = ss - 1
    /\ IF nw > ns
       THEN LET k == IF MUTANT = "broadcast_one" THEN 1 ELSE nw - ns
            IN /\ ns' = ns + k            \* = num_waiting unless mutated
               /\ kp' = [kp EXCEPT ![t] = k]
               /\ kh' = [kh EXCEPT ![t] = k]
               /\ sigs' = sigs + 1
               /\ Goto(t, "b_post")
       ELSE /\ UNCHANGED <<ns, kp, kh, sigs>>
            /\ Goto(t, "s_rel_noop")
    /\ UNCHANGED <<m, sem, hs, nw, tickets, flag, opDone>>

BPost(t) ==                                         \* for (i...) SDL_SignalSemaphore(sem)
    /\ pc[t] = "b_post"
    /\ IF kp[t] > 0
       THEN /\ sem' = sem + 1
            /\ kp' = [kp EXCEPT ![t] = @ - 1]
            /\ UNCHANGED pc
       ELSE /\ Goto(t, "b_rel")
            /\ UNCHANGED <<sem, kp>>
    /\ UNCHANGED <<m, ss, hs, nw, ns, tickets, flag, opDone, kh, sigs>>

BRel(t) ==
    /\ pc[t] = "b_rel"
    /\ ss' = ss + 1 /\ Goto(t, "b_hs")
    /\ UNCHANGED <<m, sem, hs, nw, ns, tickets, flag, opDone, kp, kh, sigs>>

BHs(t) ==                                           \* for (i...) SDL_WaitSemaphore(handshake_sem)
    /\ pc[t] = "b_hs"
    /\ IF kh[t] > 0
       THEN /\ hs > 0
            /\ hs' = hs - 1
            /\ kh' = [kh EXCEPT ![t] = @ - 1]
            /\ UNCHANGED <<pc, opDone>>
       ELSE /\ FinishOp(t)
            /\ UNCHANGED <<hs, kh>>
    /\ UNCHANGED <<m, ss, sem, nw, ns, tickets, flag, kp, sigs>>

Producer(t) ==
    PLock(t) \/ PUpdate(t) \/ PUnlock(t)
    \/ SAcq(t) \/ SPost(t) \/ SRel(t) \/ SHs(t) \/ SRelNoop(t)
    \/ BAcq(t) \/ BPost(t) \/ BRel(t) \/ BHs(t)

-----------------------------------------------------------------------------

Step(t) == IF t \in Consumers THEN Consumer(t) ELSE Producer(t)

AllDone ==
    /\ \A t \in Consumers : pc[t] = "w_done"
    /\ \A t \in Producers : pc[t] = "p_done"

Finished == AllDone /\ UNCHANGED vars

Next == (\E t \in Threads : Step(t)) \/ Finished

Spec == Init /\ [][Next]_vars /\ \A t \in Threads : SF_vars(Step(t))

-----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ m \in Threads \cup {None}
    /\ ss \in 0..1
    /\ sem \in Nat /\ hs \in Nat
    /\ nw \in Nat /\ ns \in Nat

\* num_signals never exceeds num_waiting, and num_waiting counts exactly the
\* consumers between "num_waiting++" and "num_waiting--".
RegisteredPCs ==
    IF MUTANT = "unlock_before_register" THEN {"c_rel", "c_wait", "c_ack"}
    ELSE {"c_rel", "c_unlock", "c_wait", "c_ack"}

CountsOK ==
    /\ ns <= nw
    /\ nw = Cardinality({t \in Consumers : pc[t] \in RegisteredPCs})

\* signal_sem is a lock: at most one thread inside it.
SignalSemIsLock ==
    ss + Cardinality({t \in Threads :
             pc[t] \in {"c_rel", "c_rel2", "s_post", "s_rel", "s_rel_noop", "b_post", "b_rel"}}) = 1

\* Every token in cond->sem is backed by an outstanding num_signals entry, so a
\* waiter that takes a token was really signalled. (Fails with timeouts: see
\* FINDINGS.md.)
NoStaleToken == sem <= ns

\* Every consumer gets through, and every Signal/Broadcast returns.
Termination == <>AllDone

=============================================================================
