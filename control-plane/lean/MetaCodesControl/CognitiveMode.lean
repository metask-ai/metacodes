import Std

/-! # Cognitive-mode scheduling: reading strategies as governed policy

Comprehension is semantic and unprovable, but "the same evidence point has
failed N consecutive attempts under the current reading" is host-observable.
The runtime (`src/core/cognitive_mode.zig`) maps that streak to a reading
mode — verify (proposition to check), construct (goal to make true), union
(satisfy every plausible reading at once against a delayed verdict), invert
(repetition refutes the standing interpretation) — and the note renders the
mandated mode per point. Mode SEMANTICS stay engineering; the SCHEDULE is
the policy proven here. Scheduling adds no injection source: it only
parameterizes the existing outcome note.

Each theorem names the mirroring Zig test. -/

namespace MetaCodesControl.CognitiveMode

inductive Mode where
  | verify
  | construct
  | unionAll
  | invert
  deriving Repr, DecidableEq

def rank : Mode → Nat
  | .verify => 0
  | .construct => 1
  | .unionAll => 2
  | .invert => 3

/-- Line-for-line transcription of `schedule`. -/
def schedule (streak : Nat) : Mode :=
  if streak ≤ 1 then .verify
  else if streak = 2 then .construct
  else if streak = 3 then .unionAll
  else .invert

/-- A fresh or once-failed point stays in the default verification mode:
the scheduler is harmless without repetition evidence.  Zig mirror:
"schedule is total, monotone, defaults to verify, reaches union by three". -/
theorem defaults_to_verify : schedule 0 = .verify ∧ schedule 1 = .verify := by
  constructor <;> rfl

/-- Three consecutive failures reach the union reading; beyond that the
terminal invert mode holds and never regresses. -/
theorem reaches_union : schedule 3 = .unionAll := by rfl

theorem terminal_invert (streak : Nat) (h : streak ≥ 4) :
    schedule streak = .invert := by
  unfold schedule
  have h1 : ¬streak ≤ 1 := by omega
  have h2 : ¬streak = 2 := by omega
  have h3 : ¬streak = 3 := by omega
  simp [h1, h2, h3]

/-- Rank in closed arithmetic form (Nat subtraction floors at zero). -/
theorem rank_schedule (n : Nat) : rank (schedule n) = min (n - 1) 3 := by
  unfold schedule
  by_cases h1 : n ≤ 1
  · simp [h1, rank]; omega
  · by_cases h2 : n = 2
    · simp [h1, h2, rank]; omega
    · by_cases h3 : n = 3
      · simp [h1, h2, h3, rank]; omega
      · simp [h1, h2, h3, rank]; omega

/-- The schedule never regresses: more accumulated refutation never sends
the reader back to an exhausted mode. -/
theorem monotone (a b : Nat) (h : a ≤ b) :
    rank (schedule a) ≤ rank (schedule b) := by
  rw [rank_schedule, rank_schedule]
  omega

end MetaCodesControl.CognitiveMode
