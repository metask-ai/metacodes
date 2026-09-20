import Std

/-! # Delivery cadence: formal policy

The runtime (`src/core/delivery_cadence.zig`) counts exploration-only tool
calls (read-only tools, read-only Bash) from the start of a run and, at the
turn boundary, injects a bounded nudge when the count crosses a threshold
while no file has been created or changed. The first mutation disarms the
gate for the rest of the run. Like the requirement ledger, the sensor (what
counts as exploration, what counts as a mutation) stays engineering; the
POLICY is proven here:

* mutation disarms — once a mutation was seen the decision is never a nudge;
* pristine harmlessness — below the first threshold a fresh gate never fires;
* ordered one-shot levels — the first level fires only at level 0 and the
  second only at level 1, so each threshold is consumed at most once and in
  order;
* bounded actuation — over any interleaving of counter growth and decisions
  the level never exceeds `maxNudges`, hence at most `maxNudges` nudges.

Each theorem names the mirroring Zig test. -/

namespace MetaCodesControl.DeliveryCadence

def maxNudges : Nat := 2

structure Thresholds where
  first : Nat
  second : Nat
  deriving Repr, DecidableEq

structure State where
  readOnlyCalls : Nat
  mutationSeen : Bool
  level : Nat
  deriving Repr, DecidableEq

inductive Decision where
  | none
  | first
  | second
  deriving Repr, DecidableEq

/-- Line-for-line transcription of `State.decide`. -/
def decide (t : Thresholds) (s : State) : Decision :=
  if s.mutationSeen then .none
  else if s.level = 0 ∧ t.first ≤ s.readOnlyCalls then .first
  else if s.level = 1 ∧ t.second ≤ s.readOnlyCalls then .second
  else .none

/-- A seen mutation disarms the gate whatever the counter or level.  Zig
mirror: "mutation disarms the cadence gate". -/
theorem mutation_disarms (t : Thresholds) (s : State) (h : s.mutationSeen = true) :
    decide t s = .none := by
  unfold decide
  simp [h]

/-- Pristine harmlessness: a fresh gate below the first threshold never
fires.  Zig mirror: "below the first threshold nothing fires". -/
theorem pristine_never_nudged (t : Thresholds) (s : State)
    (hl : s.level = 0) (hc : s.readOnlyCalls < t.first) :
    decide t s = .none := by
  unfold decide
  have h1 : ¬ (s.level = 0 ∧ t.first ≤ s.readOnlyCalls) := by
    intro h
    exact absurd h.2 (Nat.not_le.mpr hc)
  have h2 : ¬ (s.level = 1 ∧ t.second ≤ s.readOnlyCalls) := by
    intro h
    rw [hl] at h
    exact absurd h.1 (by decide)
  by_cases hm : s.mutationSeen
  · simp [hm]
  · simp [hm, h1, h2]

/-- The first level is decided only from level 0, past the first threshold,
with no mutation.  Zig mirror: "levels fire in order, at most once each,
never past the budget". -/
theorem first_requires_threshold (t : Thresholds) (s : State)
    (h : decide t s = .first) :
    s.level = 0 ∧ t.first ≤ s.readOnlyCalls ∧ s.mutationSeen = false := by
  unfold decide at h
  by_cases hm : s.mutationSeen
  · simp [hm] at h
  · by_cases h1 : s.level = 0 ∧ t.first ≤ s.readOnlyCalls
    · exact ⟨h1.1, h1.2, by simpa using hm⟩
    · by_cases h2 : s.level = 1 ∧ t.second ≤ s.readOnlyCalls
      · simp [hm, h1, h2] at h
      · simp [hm, h1, h2] at h

/-- The second level is decided only from level 1 (the first level was
consumed), past the second threshold, with no mutation.  Zig mirror:
"levels fire in order, at most once each, never past the budget". -/
theorem second_requires_first_fired (t : Thresholds) (s : State)
    (h : decide t s = .second) :
    s.level = 1 ∧ t.second ≤ s.readOnlyCalls ∧ s.mutationSeen = false := by
  unfold decide at h
  by_cases hm : s.mutationSeen
  · simp [hm] at h
  · by_cases h1 : s.level = 0 ∧ t.first ≤ s.readOnlyCalls
    · simp [hm, h1] at h
    · by_cases h2 : s.level = 1 ∧ t.second ≤ s.readOnlyCalls
      · exact ⟨h2.1, h2.2, by simpa using hm⟩
      · simp [hm, h1, h2] at h

/-- Any non-none decision comes from a level strictly below the budget. -/
theorem decision_needs_level_below_max (t : Thresholds) (s : State)
    (h : decide t s ≠ .none) : s.level < maxNudges := by
  unfold decide at h
  by_cases hm : s.mutationSeen
  · simp [hm] at h
  · by_cases h1 : s.level = 0 ∧ t.first ≤ s.readOnlyCalls
    · rw [h1.1]; decide
    · by_cases h2 : s.level = 1 ∧ t.second ≤ s.readOnlyCalls
      · rw [h2.1]; decide
      · simp [hm, h1, h2] at h

/-- Line-for-line transcription of the turn-boundary actuation: a decided
threshold is consumed (`noteDecided`), nothing else changes. -/
def step (t : Thresholds) (s : State) : State :=
  if decide t s = .none then s else { s with level := s.level + 1 }

theorem step_level_le (t : Thresholds) (s : State) (h : s.level ≤ maxNudges) :
    (step t s).level ≤ maxNudges := by
  unfold step
  by_cases hd : decide t s = .none
  · rw [if_pos hd]
    exact h
  · rw [if_neg hd]
    exact decision_needs_level_below_max t s hd

/-- One turn: the sensor adds `calls` exploration calls (or reports a
mutation), then the boundary decides. -/
def turn (t : Thresholds) (s : State) (calls : Nat) (mutation : Bool) : State :=
  step t { s with
    readOnlyCalls := if mutation then s.readOnlyCalls else s.readOnlyCalls + calls,
    mutationSeen := s.mutationSeen || mutation }

def run (t : Thresholds) : List (Nat × Bool) → State → State
  | [], s => s
  | (calls, mutation) :: rest, s => run t rest (turn t s calls mutation)

/-- Bounded actuation over ANY trace of turns: the level, and therefore the
number of nudges, never exceeds the budget.  Zig mirror: "levels fire in
order, at most once each, never past the budget". -/
theorem level_bounded (t : Thresholds) (trace : List (Nat × Bool)) (s : State)
    (h : s.level ≤ maxNudges) : (run t trace s).level ≤ maxNudges := by
  induction trace generalizing s with
  | nil => exact h
  | cons head rest ih =>
    obtain ⟨calls, mutation⟩ := head
    exact ih _ (step_level_le t _ h)

/-- A fresh gate starts at level 0, so every real run is within budget. -/
theorem fresh_run_bounded (t : Thresholds) (trace : List (Nat × Bool)) (calls : Nat) :
    (run t trace { readOnlyCalls := calls, mutationSeen := false, level := 0 }).level ≤ maxNudges :=
  level_bounded t trace _ (Nat.zero_le _)

end MetaCodesControl.DeliveryCadence
