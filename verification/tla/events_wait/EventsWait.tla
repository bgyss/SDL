----------------------------- MODULE EventsWait -----------------------------
(***************************************************************************)
(* Model of SDL_WaitEvent's wakeup protocol (src/events/SDL_events.c):     *)
(* one thread waiting in SDL_WaitEventTimeout_Device (:1631-1688 at        *)
(* cb6224d2e) while other threads push events, each push followed by       *)
(* SDL_SendWakeupEvent (:1166-1182). FIX = FALSE is the pre-fix code       *)
(* (cb6224d2e); FIX = TRUE is the code since cce7d368b (MC_fix.cfg), and   *)
(* Trace.tla checks real runs of it against this model.                    *)
(*                                                                         *)
(* Waiter, entry check in SDL_WaitEventTimeoutNS, before the device loop   *)
(* (added 2026-11-05, after trace validation showed the model lacked it):  *)
(*   w_epump  SDL_PumpEventsInternal (native := 0)                         *)
(*   w_epeep  SDL_PeepEvents(GET) without publishing wakeup_window: take   *)
(*            an event and return it, or enter the device loop.            *)
(* Waiter, one loop iteration of SDL_WaitEventTimeout_Device:              *)
(*   w_pump   SDL_PumpEventsInternal: the backend handles every pending    *)
(*            native event, including earlier wakeup events (native := 0). *)
(*   w_peep   SDL_PeepEvents(GET) under the queue lock: take an event if   *)
(*            there is one and return it to the application.               *)
(*   w_set    SetAtomicPointer(&wakeup_window, window)        (:1671)      *)
(*   w_enter  the call into _this->WaitEventTimeout, before it blocks       *)
(*   w_wait   _this->WaitEventTimeout: block until a native event arrives  *)
(*            (or, with TIMED, until the timeout).                         *)
(*   w_clear  SetAtomicPointer(&wakeup_window, NULL)          (:1673)      *)
(*            then, after a native event, loop (w_pump); after a timeout,  *)
(*            return to the application (w_epump).                         *)
(*   w_untake (FIX only) after taking an event, the fixed code clears      *)
(*            wakeup_window in a separate step before returning. A         *)
(*            producer may swap the window in between and post a           *)
(*            wakeup nobody waits for; the next pump drains it.            *)
(* The application calls SDL_WaitEvent again after each event (or after a  *)
(* timeout) until it has received one event per producer.                  *)
(*                                                                         *)
(* Producer: SDL_PushEvent = PeepEvents(ADD) under the queue lock          *)
(* (p_push), then SDL_SendWakeupEvent: atomically swap wakeup_window with  *)
(* NULL (p_swap) and, if it was set, post a native event (p_post).         *)
(*                                                                         *)
(* Backend abstraction (RESEARCH open question 1, answered by reading      *)
(* Cocoa_SendWakeupEvent/WaitEventTimeout, X11, Win32): the wakeup is a    *)
(* native event (NSApp postEvent / XSendEvent / PostMessage) that the OS   *)
(* queues until the waiter reads it, so it is a latched counter `native`.  *)
(* No backend re-checks SDL's own queue before blocking. Other OS events   *)
(* (input, timers) that could also end the wait are not modelled.          *)
(*                                                                         *)
(* FIX = TRUE models the publish-then-check order: set wakeup_window       *)
(* before the last queue check (w_set before w_peep), not after it.        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Producers, TIMED, FIX, MUTANT

ASSUME TIMED \in BOOLEAN /\ FIX \in BOOLEAN
ASSUME MUTANT \in {"none",
                   "no_latch",          \* a wakeup posted while the waiter is not blocked is dropped
                   "wake_before_push",  \* producer sends the wakeup before pushing the event
                   "take_twice",        \* peep removes one event but counts two
                   "peep_may_skip"}     \* peep may ignore a queued event

N == Cardinality(Producers)
NULL == "NULL"
W == "W"

VARIABLES
    q,        \* SDL event queue length
    ww,       \* _this->wakeup_window
    native,   \* latched native wakeup events
    wpc,      \* waiter's location
    ppc,      \* producers' locations
    swapped,  \* what each producer's swap returned
    got       \* events the application has received

vars == <<q, ww, native, wpc, ppc, swapped, got>>

Init ==
    /\ q = 0 /\ ww = NULL /\ native = 0 /\ got = 0
    /\ wpc = "w_epump"
    /\ ppc = [p \in Producers |-> IF MUTANT = "wake_before_push" THEN "p_swap" ELSE "p_push"]
    /\ swapped = [p \in Producers |-> NULL]

pushed == Cardinality({p \in Producers :
            IF MUTANT = "wake_before_push" THEN ppc[p] = "p_done"
            ELSE ppc[p] \notin {"p_push"}})

-----------------------------------------------------------------------------
(* Waiter *)

AfterPump == IF FIX THEN "w_set" ELSE "w_peep"
\* Where the waiter goes after returning an event to the application, which calls again.
AfterReturn == IF got' >= N THEN "w_done" ELSE "w_epump"

\* SDL_WaitEventTimeoutNS: pump, then look at the queue once before the device loop.
WEPump ==
    /\ wpc = "w_epump"
    /\ native' = 0
    /\ wpc' = "w_epeep"
    /\ UNCHANGED <<q, ww, ppc, swapped, got>>

WEPeepTake ==
    /\ wpc = "w_epeep"
    /\ q > 0
    /\ q' = q - 1
    /\ got' = got + 1
    /\ wpc' = AfterReturn
    /\ UNCHANGED <<ww, native, ppc, swapped>>

WEPeepEmpty ==
    /\ wpc = "w_epeep"
    /\ (q = 0 \/ MUTANT = "peep_may_skip")
    /\ wpc' = "w_pump"
    /\ UNCHANGED <<q, ww, native, ppc, swapped, got>>

WPump ==
    /\ wpc = "w_pump"
    /\ native' = 0
    /\ wpc' = AfterPump
    /\ UNCHANGED <<q, ww, ppc, swapped, got>>

\* An event is there: take it and return it to the application, which calls again (or stops).
WPeepTake ==
    /\ wpc = "w_peep"
    /\ q > 0
    /\ q' = q - 1
    /\ got' = got + (IF MUTANT = "take_twice" THEN 2 ELSE 1)
    \* With FIX the waiter published wakeup_window first; it clears it on the way out (w_untake).
    /\ wpc' = IF FIX THEN "w_untake" ELSE AfterReturn
    /\ UNCHANGED <<ww, native, ppc, swapped>>

WUntake ==
    /\ wpc = "w_untake"
    /\ ww' = NULL
    /\ wpc' = IF got >= N THEN "w_done" ELSE "w_epump"
    /\ UNCHANGED <<q, native, ppc, swapped, got>>

WPeepEmpty ==
    /\ wpc = "w_peep"
    /\ (q = 0 \/ MUTANT = "peep_may_skip")
    /\ wpc' = IF FIX THEN "w_enter" ELSE "w_set"
    /\ UNCHANGED <<q, ww, native, ppc, swapped, got>>

WSet ==
    /\ wpc = "w_set"
    /\ ww' = W
    /\ wpc' = IF FIX THEN "w_peep" ELSE "w_enter"
    /\ UNCHANGED <<q, native, ppc, swapped, got>>

\* The call into _this->WaitEventTimeout, before the backend actually blocks. A wakeup posted
\* now must survive until the wait starts (the "no_latch" mutant drops it).
WEnter ==
    /\ wpc = "w_enter"
    /\ wpc' = "w_wait"
    /\ UNCHANGED <<q, ww, native, ppc, swapped, got>>

\* The backend wait returns when a native event is there (the pump step after w_clear
\* handles it) ...
WWaitNative ==
    /\ wpc = "w_wait"
    /\ native > 0
    /\ wpc' = "w_clear_loop"
    /\ UNCHANGED <<q, ww, native, ppc, swapped, got>>

\* ... or, for a timed wait, when the timeout expires (SDL_WaitEventTimeout returns false and
\* the application calls it again).
WWaitTimeout ==
    /\ wpc = "w_wait"
    /\ TIMED
    /\ wpc' = "w_clear_ret"
    /\ UNCHANGED <<q, ww, native, ppc, swapped, got>>

\* After a native event the device loop goes round again; after a timeout it returns.
WClear ==
    /\ wpc \in {"w_clear_loop", "w_clear_ret"}
    /\ ww' = NULL
    /\ wpc' = IF wpc = "w_clear_loop" THEN "w_pump" ELSE "w_epump"
    /\ UNCHANGED <<q, native, ppc, swapped, got>>

Waiter == WEPump \/ WEPeepTake \/ WEPeepEmpty \/ WPump \/ WPeepTake \/ WUntake \/ WPeepEmpty
          \/ WSet \/ WEnter \/ WWaitNative \/ WWaitTimeout \/ WClear

-----------------------------------------------------------------------------
(* Producers *)

PPush(p) ==
    /\ ppc[p] = "p_push"
    /\ q' = q + 1
    /\ ppc' = [ppc EXCEPT ![p] = IF MUTANT = "wake_before_push" THEN "p_done" ELSE "p_swap"]
    /\ UNCHANGED <<ww, native, wpc, swapped, got>>

\* SDL_SetAtomicPointer(&_this->wakeup_window, NULL) returns the old value (:1177).
PSwap(p) ==
    /\ ppc[p] = "p_swap"
    /\ swapped' = [swapped EXCEPT ![p] = ww]
    /\ ww' = NULL
    /\ ppc' = [ppc EXCEPT ![p] = "p_post"]
    /\ UNCHANGED <<q, native, wpc, got>>

\* if (wakeup_window) _this->SendWakeupEvent(_this, wakeup_window);
PPost(p) ==
    /\ ppc[p] = "p_post"
    /\ native' = IF swapped[p] = W /\ (MUTANT # "no_latch" \/ wpc = "w_wait")
                 THEN native + 1 ELSE native
    /\ ppc' = [ppc EXCEPT ![p] = IF MUTANT = "wake_before_push" THEN "p_push" ELSE "p_done"]
    /\ UNCHANGED <<q, ww, wpc, swapped, got>>

Producer(p) == PPush(p) \/ PSwap(p) \/ PPost(p)

-----------------------------------------------------------------------------

AllDone == wpc = "w_done" /\ \A p \in Producers : ppc[p] = "p_done"

\* Explicit stuttering once everything has finished, so that normal termination is not
\* reported as a deadlock. Any other state with no enabled step *is* a deadlock: the waiter is
\* blocked in w_wait for good.
Terminated == AllDone /\ UNCHANGED vars

Next == Waiter \/ (\E p \in Producers : Producer(p)) \/ Terminated

Spec == Init /\ [][Next]_vars /\ WF_vars(Waiter) /\ \A p \in Producers : WF_vars(Producer(p))

-----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ q \in 0..N /\ got \in 0..(2 * N) /\ native \in 0..N
    /\ ww \in {NULL, W}
    /\ wpc \in {"w_epump", "w_epeep", "w_pump", "w_peep", "w_untake", "w_set", "w_enter",
                "w_wait", "w_clear_loop", "w_clear_ret", "w_done"}
    /\ \A p \in Producers : ppc[p] \in {"p_push", "p_swap", "p_post", "p_done"}

\* Every pushed event is either still queued or was delivered exactly once.
Conservation == got + q = pushed

\* A wakeup that can still arrive: a producer that has not yet swapped, or has swapped the
\* window and not yet posted.
WakeupComing == \E p \in Producers :
    \/ ppc[p] \in {"p_push", "p_swap"}
    \/ (ppc[p] = "p_post" /\ swapped[p] = W)

\* The lost-wakeup hypothesis (FINDINGS L-4), as a state predicate: the waiter is blocked in
\* the backend with an event in SDL's queue, no native event pending, and no wakeup on the way.
\* Only a timeout (or an unrelated OS event) can end this wait.
NoLostWakeup == ~(wpc = "w_wait" /\ q > 0 /\ native = 0 /\ ~WakeupComing)

\* The application eventually receives every event.
AllDelivered == <>(got >= N)

=============================================================================
