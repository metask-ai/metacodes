import Std

/-! # Progress updates: formal policy

The runtime (`src/core/progress_updates.zig`) observes every turn: visible
model text ends a silent stretch, a tool round without it lengthens the
stretch by one round, and the stretch also has a wall-clock length measured
from the last visible text. At the turn boundary it injects a bounded nudge
asking for a short progress note once the stretch is long enough in BOTH
rounds and time. Like the delivery cadence, the sensor (what counts as
visible text, how time is measured) stays engineering; the POLICY is proven
here:

* narration resets — the boundary right after a turn with visible text never
  nudges (whatever the turn did otherwise);
* below-threshold harmlessness — fewer silent rounds than the round
  threshold, or less silence than the time floor, never fires;
* bounded actuation — over any interleaving of turns and decisions the
  decision count never exceeds `maxNudges`, hence at most `maxNudges`
  nudges (an injection is at most one per decision).

Each theorem names the mirroring Zig test. -/

namespace MetaCodesControl.ProgressUpdates

/-- Mirrors the Zig `MAX_PROGRESS_NUDGES` (lockstep-checked by
`scripts/eval/tests/test_delivery_cadence_constants.py`). -/
def maxNudges : Nat := 2

structure Thresholds where
  rounds : Nat
  minSilent : Nat
  deriving Repr, DecidableEq

/-- `decisions` mirrors the Zig `State.decisions`: nudges in enforced mode,
would-have-nudged in observe mode; injections are at most one per decision. -/
structure State where
  silentRounds : Nat
  silentFor : Nat
  decisions : Nat
  deriving Repr, DecidableEq

/-- Transcription of `State.decide`. -/
def decide (t : Thresholds) (s : State) : Bool :=
  if s.decisions < maxNudges ∧ t.rounds ≤ s.silentRounds ∧ t.minSilent ≤ s.silentFor
  then true else false

/-- Transcription of `State.observeTurn`: visible text ends the stretch, a
silent tool round lengthens it, a silent turn without tools only lets the
clock run. `elapsed` is the wall-clock length of the turn. -/
def observe (s : State) (visible toolUse : Bool) (elapsed : Nat) : State :=
  if visible then { s with silentRounds := 0, silentFor := 0 }
  else if toolUse then
    { s with silentRounds := s.silentRounds + 1, silentFor := s.silentFor + elapsed }
  else { s with silentFor := s.silentFor + elapsed }

/-- Transcription of the turn-boundary actuation (`State.noteDecided`): a
decision is counted and the stretch restarts, nothing else changes. -/
def step (t : Thresholds) (s : State) : State :=
  if decide t s then { s with decisions := s.decisions + 1, silentRounds := 0, silentFor := 0 }
  else s

/-- Narration resets: the boundary after a turn with visible text never
nudges when at least one silent round is required. Zig mirror: "silent tool
rounds accumulate, visible text resets rounds and the clock". -/
theorem narrated_never_nudged (t : Thresholds) (s : State) (u : Bool) (e : Nat)
    (hr : 0 < t.rounds) : decide t (observe s true u e) = false := by
  unfold decide observe
  simp
  omega

/-- Fewer silent rounds than the threshold never fires. Zig mirror: "the
policy needs both thresholds". -/
theorem below_rounds_never_fires (t : Thresholds) (s : State)
    (h : s.silentRounds < t.rounds) : decide t s = false := by
  unfold decide
  simp
  omega

/-- Less silence than the time floor never fires, however many rounds. Zig
mirror: "the policy needs both thresholds". -/
theorem quick_rounds_never_fire (t : Thresholds) (s : State)
    (h : s.silentFor < t.minSilent) : decide t s = false := by
  unfold decide
  simp
  omega

/-- Any positive decision comes from a count strictly below the budget. -/
theorem decision_needs_budget (t : Thresholds) (s : State)
    (h : decide t s = true) : s.decisions < maxNudges := by
  unfold decide at h
  by_cases hc : s.decisions < maxNudges ∧ t.rounds ≤ s.silentRounds ∧ t.minSilent ≤ s.silentFor
  · exact hc.1
  · simp [hc] at h

theorem step_decisions_le (t : Thresholds) (s : State) (h : s.decisions ≤ maxNudges) :
    (step t s).decisions ≤ maxNudges := by
  unfold step
  by_cases hd : decide t s = true
  · rw [if_pos hd]
    exact decision_needs_budget t s hd
  · rw [if_neg hd]
    exact h

/-- The sensor never touches the decision count. -/
theorem observe_decisions (s : State) (v u : Bool) (e : Nat) :
    (observe s v u e).decisions = s.decisions := by
  unfold observe
  cases v <;> cases u <;> simp

/-- One turn: the sensor observes, then the boundary decides. -/
def turn (t : Thresholds) (s : State) (visible toolUse : Bool) (elapsed : Nat) : State :=
  step t (observe s visible toolUse elapsed)

def run (t : Thresholds) : List (Bool × Bool × Nat) → State → State
  | [], s => s
  | (visible, toolUse, elapsed) :: rest, s => run t rest (turn t s visible toolUse elapsed)

/-- Bounded actuation over ANY trace of turns: the decision count, and
therefore the number of nudges, never exceeds the budget. Zig mirror: "never
passes the bound". -/
theorem decisions_bounded (t : Thresholds) (trace : List (Bool × Bool × Nat)) (s : State)
    (h : s.decisions ≤ maxNudges) : (run t trace s).decisions ≤ maxNudges := by
  induction trace generalizing s with
  | nil => exact h
  | cons head rest ih =>
    obtain ⟨visible, toolUse, elapsed⟩ := head
    apply ih
    unfold turn
    apply step_decisions_le
    rw [observe_decisions]
    exact h

/-- A fresh gate starts with no decisions, so every real run is within budget. -/
theorem fresh_run_bounded (t : Thresholds) (trace : List (Bool × Bool × Nat)) :
    (run t trace { silentRounds := 0, silentFor := 0, decisions := 0 }).decisions ≤ maxNudges :=
  decisions_bounded t trace _ (Nat.zero_le _)

end MetaCodesControl.ProgressUpdates
