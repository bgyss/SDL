import SDLVerif

/-! Run with `lake env lean test/Axioms.lean`. `mise run lean` fails if any theorem depends on
`sorryAx` or on an axiom outside the standard three and the auxiliary axioms that `bv_decide`
introduces for its natively checked LRAT certificates (`*._native.bv_decide.*`). -/

open SDLVerif.Utf8 in
#print axioms reads_le_slen
open SDLVerif.Utf8 in
#print axioms progress
open SDLVerif.Utf8 in
#print axioms stops_at_end
open SDLVerif.Utf8 in
#print axioms complete
open SDLVerif.Utf8 in
#print axioms sound_in_range
open SDLVerif.Utf8 in
#print axioms accepts_out_of_range
open SDLVerif.Utf8 in
#print axioms out_of_range_iff
open SDLVerif.Utf8 in
#print axioms null_len_reads_past_nul
open SDLVerif.Utf8 in
#print axioms fixed_sound
open SDLVerif.Utf8 in
#print axioms fixed_complete
open SDLVerif.Utf8 in
#print axioms fixed_stops_at_nul
open SDLVerif.Utf8 in
#print axioms fix_changes_only_out_of_range
