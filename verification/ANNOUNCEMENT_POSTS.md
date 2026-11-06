# Announcement posts: formally verifying (parts of) SDL3

Drafts for LinkedIn, X and Reddit about the work in `verification/` of the `bgyss/SDL` fork.
Before posting, check the numbers against `verification/FINDINGS.md`. Say plainly that this is
an independent, agent-driven fork and that none of it is upstream SDL work.

---

## LinkedIn

**What happens when you point LLM agents, Lean 4 and TLA+ at a real C library?**

Over the past few days I ran an experiment on SDL3, the cross-platform media library behind a
huge number of games, in my own fork. The agents did almost all of the work: formal
verification, fuzzing, bug fixes.

What came out of it:

- **Lean 4 proofs** about SDL's UTF-8 code: decoding, encoding, reverse stepping and safe
  copying. These are checked over all 2³² inputs where that applies, and tied back to the real
  C by differential testing (3.1M boundary cases plus thousands of fuzzer strings).
- **TLA+ models** of SDL's concurrency, including the event wait/wakeup protocol and the audio
  device lifetime.
- **Six libFuzzer harnesses** whose properties double as specs.
- **About 17 real bugs**: out-of-bounds reads in the gamepad mapping parser, a UTF-8 decoder
  that accepted code points above U+10FFFF, signed overflows in the rect math, and WAV channel
  counts truncated to 8 bits.

The one I like most: the TLA+ model found a **lost wakeup** in `SDL_WaitEvent`, an 8-step
interleaving where an event pushed from another thread never wakes the waiter. A stress test
then reproduced it on a real Mac: 13 hits in 300,000 rounds. After the fix: 0 in 500,000.

What I took away from it:

1. Specs written from tests and fuzzers are the practical way in.
2. Every property needs a mutant that breaks it, or you can't tell a real proof from a vacuous one.
3. "Formally verified" means nothing unless the model is tied back to the actual code.

This is a personal fork, not affiliated with the SDL project. Upstream SDL doesn't accept
AI-generated contributions, and I respect that, so none of this is being sent upstream.

#FormalVerification #Lean4 #TLAPlus #AI #SoftwareEngineering #Fuzzing

---

## X (thread)

1/ I pointed LLM agents plus Lean 4 plus TLA+ at SDL3, the C media library a lot of games ship
with, in my own fork. About 17 real bugs found and fixed, with proofs and models tied back to
the C. 🧵

2/ Lean: SDL's UTF-8 decoder, encoder, StepBack and strlcpy are modelled bit-for-bit and proved
against RFC 3629 over all 2³² inputs. One theorem pins down *exactly* which inputs the decoder
got wrong: values above U+10FFFF.

3/ TLA+: SDL_WaitEvent had a lost wakeup. An event pushed between the queue check and
publishing the wakeup window never wakes the waiter. The model found it in 8 steps; a stress
test hit it 13 times in 300k rounds on macOS. After the fix: 0 in 500k.

4/ Fuzzing, with properties as specs: out-of-bounds reads in gamepad mapping parsing, rect math
overflows, a WAV loader that turns 256 channels into 0, BMP RLE pointer UB.

5/ Lessons: every property needs a mutant that breaks it. Differential-test every model
against the real code. "Verified" without stated bounds and a trusted base is marketing.

6/ This is an independent fork and test bed, not upstream SDL, which (rightly) doesn't take AI
contributions. Everything is in verification/ in bgyss/SDL.

---

## Reddit (r/programming, r/gamedev, r/ProgrammingLanguages)

**Title:** I used LLM agents with Lean 4 and TLA+ to formally verify parts of SDL3 in a fork,
and found about 17 real bugs, including a lost wakeup in SDL_WaitEvent

**Body:**

This is an experiment on my own fork of SDL3 (`bgyss/SDL`), which is not affiliated with the
SDL project. Upstream SDL's policy is not to accept AI-generated contributions, so nothing here
was submitted upstream. I'm posting it as a data point on what agent-driven formal verification
of a real C codebase looks like today.

**Method**
- **Lean 4** for small, pure functions. The C is transcribed with exact integer widths as
  `BitVec`, and properties are proved with `bv_decide` against an independent RFC 3629
  grammar. The models are tied to the real C by differential tests: 3.1M boundary cases plus
  about 3,000 fuzzer strings. Each theorem has a mutant that must break it.
- **TLA+** for concurrency: init/quit state, the generic condition variable, the event
  wait/wakeup protocol, and the audio device refcount lifetime. Bounds are stated with every
  result.
- **libFuzzer** with ASan and UBSan on the UTF-8 code, iconv, rects, gamepad mappings, BMP
  and WAV. Each harness checks properties, not just crashes.

**Some findings** (all now fixed in the fork):
- `SDL_WaitEvent` lost wakeup: TLA+ counterexample, reproduced on macOS. 13 hits in 300k rounds
  before the fix, 0 in 500k after.
- `SDL_StepUTF8(&p, NULL)`, and through it `SDL_strcasecmp`, reads up to 2 bytes past the NUL
  on truncated UTF-8.
- The gamepad mapping parser reads `buf[-1]` on an empty binding; a 128-character binding
  overflows a stack buffer.
- `SDL_utf8strlcpy` can leave a truncated character. That one is proved exactly when it happens.
- The audio device lookup can use a device after a concurrent disconnect frees it (TLA+). The
  obvious fix is *also* wrong in the model.

**What worked / what didn't**
- Mutants for every property caught several vacuous specs early.
- Mirroring a parser's exact rewrite pipeline in a fuzz harness, to skip known bugs, is a trap.
  Just fix the bug.
- Trace validation, which checks TLA+ models against real execution traces, is still to do.

Write-ups, proofs and repro steps are in `verification/` in the repo. Happy to answer questions.
