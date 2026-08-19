import Std

/-! # Requirement-ledger closure obligation: formal policy

The runtime (`src/core/requirement_ledger.zig`) counts the model's own task
ledger at a premature final answer and may inject one bounded nudge per
round: open items must be completed or explicitly closed; a mutating session
that ignored the ledger prompt gets one coverage nudge; a mutating session
that closed everything but enumerated almost nothing gets one shallow
re-scan nudge (p3 production forensics: failing tasks recorded 2-4 items
against verifiers checking 11-15 facets, and `open_at_final = 0` made the
original gate blind to them). As with the verification gate, the
classifiers (what counts as a ledger item) stay engineering; the POLICY is
proven here:

* pristine harmlessness — a session that neither mutated nor created ledger
  items is never nudged;
* bounded actuation — the nudge counter never exceeds its budget;
* closure disarms — with every item closed (and the ledger non-empty or the
  session non-mutating), the open-items nudge cannot fire;
* coverage fires at most once and only after the prompt was given;
* shallow fires at most once, only after the prompt, only on a mutating
  session, and never outranks open items.

Each theorem names the mirroring Zig test. -/

namespace MetaCodesControl.RequirementLedger

structure State where
  promptEmitted : Bool
  coverageUsed : Bool
  shallowUsed : Bool
  mutations : Bool
  itemsTotal : Nat
  itemsOpen : Nat
  deriving Repr, DecidableEq

inductive Decision where
  | none
  | openItems
  | coverage
  | shallow
  deriving Repr, DecidableEq

def maxNudges : Nat := 2

def shallowFloor : Nat := 3

/-- Line-for-line transcription of `State.decide`. -/
def decide (s : State) (nudges : Nat) : Decision :=
  if nudges ≥ maxNudges then .none
  else if s.itemsOpen > 0 then .openItems
  else if 0 < s.itemsTotal ∧ s.itemsTotal ≤ shallowFloor ∧ s.mutations ∧
      s.promptEmitted ∧ ¬s.shallowUsed
  then .shallow
  else if s.itemsTotal = 0 ∧ s.mutations ∧ s.promptEmitted ∧ ¬s.coverageUsed
  then .coverage
  else .none

/-- Pristine harmlessness: no mutations and no ledger items ⇒ never nudged,
whatever the nudge count or prompt state.  Zig mirror: unit test
"pristine sessions are never nudged". -/
theorem pristine_never_nudged (s : State) (nudges : Nat)
    (hm : s.mutations = false) (ho : s.itemsOpen = 0) :
    decide s nudges = .none := by
  unfold decide
  by_cases hb : nudges ≥ maxNudges
  · simp [hb]
  · simp [hb, ho, hm]

/-- Without the prompt neither the coverage nudge nor the shallow nudge can
fire: the host does not punish the model for ignoring an instruction it was
never given.  Zig mirror: "pristine sessions are never nudged" (silent
branch) and "shallow nudge fires once on a closed-but-short ledger" (silent
branch). -/
theorem no_prompt_no_coverage (s : State) (nudges : Nat)
    (hp : s.promptEmitted = false) (ho : s.itemsOpen = 0) :
    decide s nudges = .none := by
  unfold decide
  by_cases hb : nudges ≥ maxNudges
  · simp [hb]
  · simp [hb, ho, hp]

/-- An exhausted budget always decides none. -/
theorem budget_exhausted_decides_none (s : State) (nudges : Nat)
    (h : nudges ≥ maxNudges) : decide s nudges = .none := by
  unfold decide
  simp [h]

/-- The premature-final loop increments only when a nudge is decided. -/
def nudgesAfter (finals : Nat) (s : State) : Nat :=
  Nat.rec 0
    (fun _ acc => acc + (if decide s acc = Decision.none then 0 else 1))
    finals

/-- Bounded actuation.  Zig mirror: "open items nudge until the budget is
exhausted". -/
theorem nudges_bounded (finals : Nat) (s : State) :
    nudgesAfter finals s ≤ maxNudges := by
  induction finals with
  | zero => exact Nat.zero_le _
  | succ n ih =>
    unfold nudgesAfter at ih ⊢
    by_cases hd : decide s (Nat.rec 0
        (fun _ acc => acc + (if decide s acc = Decision.none then 0 else 1)) n)
        = Decision.none
    · simpa [hd] using ih
    · have hlt : Nat.rec 0
          (fun _ acc => acc + (if decide s acc = Decision.none then 0 else 1)) n
          < maxNudges := by
        cases Nat.lt_or_ge (Nat.rec 0
            (fun _ acc => acc + (if decide s acc = Decision.none then 0 else 1)) n)
            maxNudges with
        | inl h => exact h
        | inr h =>
          exact absurd (budget_exhausted_decides_none s _ h) hd
      simpa [hd] using hlt

/-- Closure disarms the open-items nudge: with zero open items it can never
be the decision.  Zig mirror: "closure disarms and coverage fires once". -/
theorem closure_disarms_open_items (s : State) (nudges : Nat)
    (ho : s.itemsOpen = 0) :
    decide s nudges ≠ .openItems := by
  unfold decide
  by_cases hb : nudges ≥ maxNudges
  · rw [if_pos hb]; intro h; cases h
  · rw [if_neg hb, ho]
    simp only [Nat.lt_irrefl, if_false]
    by_cases hs : (0 < s.itemsTotal ∧ s.itemsTotal ≤ shallowFloor ∧
        s.mutations = true ∧ s.promptEmitted = true ∧ ¬s.shallowUsed = true)
    · rw [if_pos hs]; intro h; cases h
    · rw [if_neg hs]
      by_cases hc : (s.itemsTotal = 0 ∧ s.mutations = true ∧
          s.promptEmitted = true ∧ ¬s.coverageUsed = true)
      · rw [if_pos hc]; intro h; cases h
      · rw [if_neg hc]; intro h; cases h

/-- The coverage nudge is one-shot: once consumed (and with the empty ledger
that defines its domain) it never decides again.  Zig mirror: "closure
disarms and coverage fires once" (second half). -/
theorem coverage_is_one_shot (s : State) (nudges : Nat)
    (hu : s.coverageUsed = true) (ho : s.itemsOpen = 0)
    (ht : s.itemsTotal = 0) :
    decide s nudges = .none := by
  unfold decide
  by_cases hb : nudges ≥ maxNudges
  · simp [hb]
  · simp [hb, ho, hu, ht]

/-- The shallow nudge is one-shot: once consumed it can never be the
decision again.  Zig mirror: "shallow nudge fires once on a closed-but-short
ledger". -/
theorem shallow_is_one_shot (s : State) (nudges : Nat)
    (hu : s.shallowUsed = true) :
    decide s nudges ≠ .shallow := by
  unfold decide
  by_cases hb : nudges ≥ maxNudges
  · rw [if_pos hb]; intro h; cases h
  · rw [if_neg hb]
    by_cases hop : s.itemsOpen > 0
    · rw [if_pos hop]; intro h; cases h
    · rw [if_neg hop]
      by_cases hs : (0 < s.itemsTotal ∧ s.itemsTotal ≤ shallowFloor ∧
          s.mutations = true ∧ s.promptEmitted = true ∧ ¬s.shallowUsed = true)
      · exact absurd hs.2.2.2.2 (by simp [hu])
      · rw [if_neg hs]
        by_cases hc : (s.itemsTotal = 0 ∧ s.mutations = true ∧
            s.promptEmitted = true ∧ ¬s.coverageUsed = true)
        · rw [if_pos hc]; intro h; cases h
        · rw [if_neg hc]; intro h; cases h

/-- A non-mutating session never receives the shallow nudge.  Zig mirror:
"shallow nudge fires once on a closed-but-short ledger" (no-mutation
branch). -/
theorem no_mutations_no_shallow (s : State) (nudges : Nat)
    (hm : s.mutations = false) :
    decide s nudges ≠ .shallow := by
  unfold decide
  by_cases hb : nudges ≥ maxNudges
  · rw [if_pos hb]; intro h; cases h
  · rw [if_neg hb]
    by_cases hop : s.itemsOpen > 0
    · rw [if_pos hop]; intro h; cases h
    · rw [if_neg hop]
      by_cases hs : (0 < s.itemsTotal ∧ s.itemsTotal ≤ shallowFloor ∧
          s.mutations = true ∧ s.promptEmitted = true ∧ ¬s.shallowUsed = true)
      · exact absurd hs.2.2.1 (by simp [hm])
      · rw [if_neg hs]
        by_cases hc : (s.itemsTotal = 0 ∧ s.mutations = true ∧
            s.promptEmitted = true ∧ ¬s.coverageUsed = true)
        · rw [if_pos hc]; intro h; cases h
        · rw [if_neg hc]; intro h; cases h

end MetaCodesControl.RequirementLedger
