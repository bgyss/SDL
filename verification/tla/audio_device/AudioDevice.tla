---------------------------- MODULE AudioDevice -----------------------------
(***************************************************************************)
(* Model of the physical audio device's lifetime against concurrent lookup *)
(* by instance ID (src/audio/SDL_audio.c, commit cb6224d2e).               *)
(*                                                                         *)
(* Lookup, ObtainPhysicalAudioDevice (:481-504), any thread:               *)
(*   l_find   read-lock subsystem_rwlock, SDL_FindInHashTable, unlock      *)
(*            (:494-497). The lock is held only inside this one step.      *)
(*   l_ref    ObtainPhysicalAudioDeviceObj: RefPhysicalAudioDevice, then   *)
(*            lock device->lock (:410-416)                                 *)
(*   l_use    the caller uses the device, then ReleaseAudioDevice          *)
(*            (:418-424), whose UnrefPhysicalAudioDevice is the Unref      *)
(*            sub-steps below.                                             *)
(*                                                                         *)
(* Disconnect: SDL_AudioDeviceDisconnected (:864-876) takes a reference    *)
(* on the backend thread and queues SDL_AudioDeviceDisconnected_OnMainThread*)
(* (:792-862). That handler obtains and releases the device, then drops    *)
(* the device list's reference (first_disconnect) and the disconnect       *)
(* reference: two Unrefs.                                                  *)
(*                                                                         *)
(* UnrefPhysicalAudioDevice (:628-639):                                    *)
(*   u_dec    SDL_AtomicDecRef; if it reached 0:                           *)
(*   u_remove write-lock subsystem_rwlock, remove from the hash, unlock    *)
(*   u_free   DestroyPhysicalAudioDevice: free the device                  *)
(*                                                                         *)
(* OPEN = TRUE: the application has the device open, and the logical       *)
(* device's reference outlives the scenario. Refcount operations are       *)
(* atomic (SDL_AtomicIncRef/DecRef); the hash table is modelled by one     *)
(* "in hash" bit since only this device is involved.                       *)
(*                                                                         *)
(* FIX:                                                                    *)
(*   "none"            the real code                                       *)
(*   "ref_in_lock"     take the reference inside the read-locked find      *)
(*   "try_ref_in_lock" inside the read lock, take a reference only if the  *)
(*                     count is not already 0, else treat as not found     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Lookers, OPEN, FIX, MUTANT

ASSUME OPEN \in BOOLEAN
ASSUME FIX \in {"none", "ref_in_lock", "try_ref_in_lock"}
ASSUME MUTANT \in {"none",
                   "free_at_one",        \* Unref frees when the count reaches 1, not 0
                   "free_before_remove", \* destroy before taking the device out of the hash
                   "leak_ref"}           \* a lookup never releases its reference

Main == "main"
Threads == Lookers \cup {Main}

VARIABLES
    rc,       \* device->refcount
    inhash,   \* the device is in current_audio.device_hash_physical
    freed,    \* DestroyPhysicalAudioDevice has run
    uaf,      \* some thread touched the device after it was freed
    pc,       \* per thread
    ret,      \* where each thread's Unref returns to
    found     \* per looker: what l_find returned

vars == <<rc, inhash, freed, uaf, pc, ret, found>>

Init ==
    \* list reference + disconnect reference (+ the open logical device's reference)
    /\ rc = 2 + (IF OPEN THEN 1 ELSE 0)
    /\ inhash = TRUE /\ freed = FALSE /\ uaf = FALSE
    /\ pc = [t \in Threads |-> IF t = Main THEN "m_obtain" ELSE "l_find"]
    /\ ret = [t \in Threads |-> "none"]
    /\ found = [t \in Lookers |-> FALSE]

Goto(t, l) == pc' = [pc EXCEPT ![t] = l]
Touch == uaf' = (uaf \/ freed)   \* a dereference of the device

-----------------------------------------------------------------------------
(* UnrefPhysicalAudioDevice, as sub-steps of thread t, returning to ret[t]. *)

FreeAt == IF MUTANT = "free_at_one" THEN 1 ELSE 0

UDec(t) ==
    /\ pc[t] = "u_dec"
    /\ rc' = rc - 1
    /\ Touch
    /\ Goto(t, IF rc - 1 = FreeAt
               THEN (IF MUTANT = "free_before_remove" THEN "u_free" ELSE "u_remove")
               ELSE ret[t])
    /\ UNCHANGED <<inhash, freed, ret, found>>

URemove(t) ==
    /\ pc[t] = "u_remove"
    /\ inhash' = FALSE
    /\ Goto(t, IF MUTANT = "free_before_remove" THEN ret[t] ELSE "u_free")
    /\ UNCHANGED <<rc, freed, uaf, ret, found>>

UFree(t) ==
    /\ pc[t] = "u_free"
    /\ freed' = TRUE
    /\ Touch
    /\ Goto(t, IF MUTANT = "free_before_remove" THEN "u_remove" ELSE ret[t])
    /\ UNCHANGED <<rc, inhash, ret, found>>

CallUnref(t, back) ==
    /\ pc' = [pc EXCEPT ![t] = "u_dec"]
    /\ ret' = [ret EXCEPT ![t] = back]

Unref(t) == UDec(t) \/ URemove(t) \/ UFree(t)

-----------------------------------------------------------------------------
(* Main thread: SDL_AudioDeviceDisconnected_OnMainThread. It holds the disconnect reference,
   so its own Obtain/Release cannot free the device. *)

MObtain ==
    /\ pc[Main] = "m_obtain"
    /\ rc' = rc + 1
    /\ Touch
    /\ Goto(Main, "m_release")
    /\ UNCHANGED <<inhash, freed, ret, found>>

MRelease ==
    /\ pc[Main] = "m_release"
    /\ CallUnref(Main, "m_unref_list")
    /\ UNCHANGED <<rc, inhash, freed, uaf, found>>

MUnrefList ==
    /\ pc[Main] = "m_unref_list"
    /\ CallUnref(Main, "m_unref_disc")
    /\ UNCHANGED <<rc, inhash, freed, uaf, found>>

MUnrefDisc ==
    /\ pc[Main] = "m_unref_disc"
    /\ CallUnref(Main, "done")
    /\ UNCHANGED <<rc, inhash, freed, uaf, found>>

MainStep == MObtain \/ MRelease \/ MUnrefList \/ MUnrefDisc \/ Unref(Main)

-----------------------------------------------------------------------------
(* Lookers: ObtainPhysicalAudioDevice(devid), use, ReleaseAudioDevice. *)

\* Find under the read lock. Readers exclude u_remove (the writer), and this step is atomic,
\* so the lock is implicit. With a FIX, the reference is taken inside the same locked step.
LFind(t) ==
    /\ pc[t] = "l_find"
    /\ \/ /\ FIX = "none"
          /\ found' = [found EXCEPT ![t] = inhash]
          /\ Goto(t, IF inhash THEN "l_ref" ELSE "done")
          /\ UNCHANGED <<rc, uaf>>
       \/ /\ FIX = "ref_in_lock"
          /\ found' = [found EXCEPT ![t] = inhash]
          /\ rc' = IF inhash THEN rc + 1 ELSE rc
          /\ uaf' = (uaf \/ (inhash /\ freed))
          /\ Goto(t, IF inhash THEN "l_use" ELSE "done")
       \/ /\ FIX = "try_ref_in_lock"
          /\ LET ok == inhash /\ rc > 0 IN
               /\ found' = [found EXCEPT ![t] = ok]
               /\ rc' = IF ok THEN rc + 1 ELSE rc
               /\ uaf' = (uaf \/ (inhash /\ freed))
               /\ Goto(t, IF ok THEN "l_use" ELSE "done")
    /\ UNCHANGED <<inhash, freed, ret>>

\* RefPhysicalAudioDevice after the lock was dropped (real code only).
LRef(t) ==
    /\ pc[t] = "l_ref"
    /\ rc' = rc + 1
    /\ Touch
    /\ Goto(t, "l_use")
    /\ UNCHANGED <<inhash, freed, ret, found>>

\* SDL_LockMutex(device->lock), the caller's work, then ReleaseAudioDevice.
LUse(t) ==
    /\ pc[t] = "l_use"
    /\ Touch
    /\ IF MUTANT = "leak_ref"
       THEN Goto(t, "done") /\ UNCHANGED ret
       ELSE CallUnref(t, "done")
    /\ UNCHANGED <<rc, inhash, freed, found>>

Looker(t) == LFind(t) \/ LRef(t) \/ LUse(t) \/ Unref(t)

-----------------------------------------------------------------------------

AllDone == \A t \in Threads : pc[t] = "done"
Terminated == AllDone /\ UNCHANGED vars

Next == MainStep \/ (\E t \in Lookers : Looker(t)) \/ Terminated

Spec == Init /\ [][Next]_vars /\ WF_vars(MainStep) /\ \A t \in Lookers : WF_vars(Looker(t))

-----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    \* list + disconnect + open logical device + main's Obtain + one per looker
    /\ rc \in 0..(4 + Cardinality(Lookers))
    /\ inhash \in BOOLEAN /\ freed \in BOOLEAN /\ uaf \in BOOLEAN

\* FINDINGS L-5: nobody dereferences the device after DestroyPhysicalAudioDevice.
NoUseAfterFree == ~uaf

\* The device is freed only after it left the hash table, so a later lookup cannot find it.
FreedImpliesUnhashed == freed => ~inhash

\* Once every thread is done, a device nobody holds open has been freed (no leaked reference).
EventuallyFreed == <>(AllDone /\ freed)

\* Every thread finishes.
Termination == <>AllDone

=============================================================================
