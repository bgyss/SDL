import Std.Tactic.BVDecide

/-
Header arithmetic of the BMP and WAV loaders (PLAN.md, Phase 5): that the size, offset and
count computations SDL does on header fields cannot overflow, divide by zero, or address
outside the buffers, for every header the C accepts.

Writing these statements found F-023/F-024. Surfaces of 2 GiB or more passed creation, and the
BMP loader's `int` product `surface->h * surface->pitch` overflowed. The theorems describe the
code since the fix (`SDL_CalculateSurfaceSize` rejects a pitch or size above INT_MAX), and
`bmp_prefix_overflow` keeps the counterexample to the old code.

Quantities the C holds in `size_t`/`Sint64` (64-bit on the platforms this fork targets) are
`Nat` here, with explicit bounds. `int` results are checked against `INT_MAX`.
-/
namespace SDLVerif.Header

def INT_MAX : Nat := 2147483647

/-! ## BMP: dimensions -/

/-- After `if (biWidth <= 0 || biHeight == 0)` and `if (biHeight == SDL_MIN_SINT32)` reject,
`biHeight = -biHeight` (for top-down images) is defined and gives a positive height. -/
theorem bmp_height_negation (biHeight : BitVec 32)
    (h0 : biHeight ≠ 0) (hmin : biHeight ≠ 0x80000000#32) (hneg : biHeight.slt 0) :
    (0 : BitVec 32).ssubOverflow biHeight = false ∧ (0#32).slt (-biHeight) := by
  bv_decide

/-! ## BMP: the surface it allocates -/

/-- `SDL_CalculateRGBSize` with 4-byte alignment (the non-minimal pitch SDL_CreateSurface uses),
for `bytesPP` bytes per pixel (formats of 8 bits or more) or `bits` bits per pixel (1, 2, 4). -/
def rawPitch (w : Nat) (bitsPP : Nat) : Nat :=
  if 8 ≤ bitsPP then w * (bitsPP / 8) else (w * bitsPP + 7) / 8

def rgbPitch (w : Nat) (bitsPP : Nat) : Nat := (rawPitch w bitsPP + 3) / 4 * 4

/-- What `SDL_CalculateSurfaceSize` decides since F-023/F-024: the surface is created only if its
pitch and total size fit in an `int`. (The `size_t` checks before it guard the computation;
see `width_times_bpp_fits` and `height_times_pitch_can_exceed_size_t`.) -/
def surfaceOk (w h bitsPP : Nat) : Prop :=
  rgbPitch w bitsPP ≤ INT_MAX ∧ h * rgbPitch w bitsPP ≤ INT_MAX

/-- On 64-bit, the `width * bytes_per_pixel` step of `SDL_CalculateRGBSize` cannot overflow
`size_t` for an `int` width and at most 16 bytes per pixel: the pitch stays below 2^36. -/
theorem width_times_bpp_fits (w bitsPP : Nat) (hw : w < 2 ^ 31) (hb : bitsPP ≤ 128) :
    rgbPitch w bitsPP < 2 ^ 36 := by
  have : rawPitch w bitsPP ≤ w * 16 := by
    unfold rawPitch
    split
    · exact Nat.mul_le_mul_left _ (by omega)
    · have : w * bitsPP ≤ w * 8 := Nat.mul_le_mul_left _ (by omega)
      omega
  unfold rgbPitch
  omega

/-- ...but `height * pitch` can exceed `size_t` (2^31 rows of a 2^35-byte pitch), so SDL's
`SDL_size_mul_check_overflow` on it is load-bearing, not redundant. -/
theorem height_times_pitch_can_exceed_size_t :
    2 ^ 64 < (2 ^ 31 - 1) * rgbPitch (2 ^ 31 - 1) 128 := by
  unfold rgbPitch rawPitch; decide

/-- A row of pixels fits in the pitch. -/
theorem pitch_holds_row (w bitsPP : Nat) (hb : 8 ≤ bitsPP) :
    w * (bitsPP / 8) ≤ rgbPitch w bitsPP := by
  unfold rgbPitch rawPitch; simp only [hb, ite_true]; omega

/-- The pitch is a multiple of 4, so the loader's padding `pitch % 4 ? 4 - pitch % 4 : 0` is 0
for surfaces it created itself. -/
theorem pitch_aligned (w bitsPP : Nat) : rgbPitch w bitsPP % 4 = 0 := by
  unfold rgbPitch; generalize rawPitch w bitsPP = p; omega

/-- **The BMP loader's buffer arithmetic** on a surface that passed creation: the `int` product
`surface->h * surface->pitch` is exact (at most INT_MAX), and every row the loop reads, row `r`
at offset `r * pitch`, lies inside the `h * pitch` bytes allocated, as does every offset in it. -/
theorem bmp_rows_in_buffer (w h bitsPP : Nat) (hok : surfaceOk w h bitsPP) :
    h * rgbPitch w bitsPP ≤ INT_MAX ∧
    ∀ r, r < h → r * rgbPitch w bitsPP + rgbPitch w bitsPP ≤ h * rgbPitch w bitsPP ∧
      r * rgbPitch w bitsPP ≤ INT_MAX := by
  obtain ⟨_, hsize⟩ := hok
  refine ⟨hsize, fun r hr => ?_⟩
  have h1 : r * rgbPitch w bitsPP + rgbPitch w bitsPP = (r + 1) * rgbPitch w bitsPP := by
    rw [Nat.succ_mul]
  have h2 : (r + 1) * rgbPitch w bitsPP ≤ h * rgbPitch w bitsPP :=
    Nat.mul_le_mul_right _ hr
  have h3 : r * rgbPitch w bitsPP ≤ h * rgbPitch w bitsPP :=
    Nat.mul_le_mul_right _ (Nat.le_of_lt hr)
  omega

/-- The record of F-023: before the fix, a 1,048,576 x 512 surface at 32 bpp passed creation
(the `size_t` checks only), and `h * pitch` is 2^31, one more than `INT_MAX`. -/
theorem bmp_prefix_overflow :
    1048576 * rgbPitch 1048576 32 ≤ 2 ^ 64 ∧ 512 * rgbPitch 1048576 32 = INT_MAX + 1 ∧
    ¬ surfaceOk 1048576 512 32 := by
  unfold surfaceOk rgbPitch rawPitch INT_MAX; decide

/-- The record of F-024: a 536,870,912-pixel row at 32 bpp has a pitch of 2^31, which does not
fit in `int`. -/
theorem pitch_prefix_overflow : rgbPitch 536870912 32 = INT_MAX + 1 := by
  unfold rgbPitch rawPitch INT_MAX; decide

/-! ## WAV: divisors and frame counts

`WaveCheckFormat` rejects `channels == 0` and `bitspersample == 0`, and forces `blockalign`
to at least 1, before any decoder init runs. The init functions compute
`blockframebitsize = bitspersample * channels` and divide by it *before* their own checks; the
prior checks are what make that safe. -/

/-- Every divisor the WAV decoders' init and sample-frame code use is non-zero. -/
theorem wav_divisors_nonzero (channels bitspersample blockalign : Nat)
    (hc : 1 ≤ channels) (hb : 1 ≤ bitspersample) (ha : 1 ≤ blockalign) :
    bitspersample * channels ≠ 0 ∧ blockalign ≠ 0 := by
  constructor
  · exact Nat.mul_ne_zero (by omega) (by omega)
  · omega

/-- The ADPCM sample-frame counts are formed in `Sint64` as
`availableblocks * samplesperblock + trailingsamples`. `datalength` comes from a 32-bit chunk
length, `samplesperblock` from a 16-bit field (or `blockdatasamples + 2`, smaller still, since
`blockalign` is 16-bit), and `trailingsamples ≤ samplesperblock`. The total is below 2^50, far
from `Sint64` overflow. -/
theorem adpcm_frames_fit (datalength blockalign samplesperblock trailing : Nat)
    (hd : datalength < 2 ^ 32) (ha : 1 ≤ blockalign) (hs : samplesperblock < 2 ^ 17)
    (ht : trailing ≤ samplesperblock) :
    datalength / blockalign * samplesperblock + trailing < 2 ^ 50 := by
  have h1 : datalength / blockalign ≤ datalength := Nat.div_le_self _ _
  have h2 : datalength / blockalign * samplesperblock < 2 ^ 32 * 2 ^ 17 := by
    calc datalength / blockalign * samplesperblock
        ≤ datalength * samplesperblock := Nat.mul_le_mul_right _ h1
      _ < 2 ^ 32 * 2 ^ 17 := by
          rcases Nat.eq_zero_or_pos samplesperblock with h0 | hpos
          · rw [h0, Nat.mul_zero]; decide
          · exact Nat.mul_lt_mul'' hd hs
  have : (2 : Nat) ^ 32 * 2 ^ 17 = 2 ^ 49 := by decide
  have : (2 : Nat) ^ 49 + 2 ^ 17 < 2 ^ 50 := by decide
  omega

end SDLVerif.Header
