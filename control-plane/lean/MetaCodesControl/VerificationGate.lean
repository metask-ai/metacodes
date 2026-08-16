import Std

/-! # Session-end verification obligation: formal state machine

The runtime sensor (`src/core/verification_progress.zig`) classifies each
completed tool turn and drives the final-gate nudge policy.  The sensor's
*classifiers* stay engineering (shell grammar, tier heuristics); what this
module owns is the **state machine and gate policy** those classifications
feed, so the gate's safety properties are proven instead of trusted:

* harmlessness — a session with no realized mutation is never nudged;
* bounded actuation — the nudge counter can never exceed its budget;
* obligation dynamics — mutation reopens, any verification tier closes,
  and the churn counter increments exactly on verified-state mutations;
* honest negative evidence — `knownFailing` (which selects the
  fix-or-report nudge variant) implies the obligation is actually open.

Each theorem names the mirroring Zig test that binds the implementation to
this model; the model's `step` is a line-for-line transcription of
`State.observeTurn`'s obligation branch. -/

namespace MetaCodesControl.VerificationGate

/-- One completed tool turn, as classified by the run-local sensor.  Tier-1 is
canonical test-runner evidence; tier-2 is a validating re-observation of a
mutated artifact; a failed attempt is a verification-shaped command with a
nonzero exit. -/
structure TurnObservation where
  realizedMutation : Bool
  tier1 : Bool
  tier2 : Bool
  failedAttempt : Bool
  deriving Repr

structure State where
  mutationSeen : Bool
  unverifiedMutation : Bool
  knownFailing : Bool
  reopenedAfterVerification : Nat
  deriving Repr, DecidableEq

def init : State :=
  { mutationSeen := false
    unverifiedMutation := false
    knownFailing := false
    reopenedAfterVerification := 0 }

/-- Obligation transition for one completed turn.  Mirrors
`verification_progress.State.observeTurn`: a mutating turn (re)opens the
obligation regardless of same-turn verification (intra-turn order is
untrusted), a verification-only turn closes it, and a failed attempt on an
open obligation records negative evidence. -/
def step (s : State) (t : TurnObservation) : State :=
  let wasVerified := s.mutationSeen && !s.unverifiedMutation
  if t.realizedMutation then
    { mutationSeen := true
      unverifiedMutation := true
      knownFailing := false
      reopenedAfterVerification :=
        s.reopenedAfterVerification + (if wasVerified then 1 else 0) }
  else if t.tier1 || t.tier2 then
    { s with unverifiedMutation := false, knownFailing := false }
  else if t.failedAttempt && s.unverifiedMutation then
    { s with knownFailing := true }
  else
    s

def run (ts : List TurnObservation) : State := ts.foldl step init

/-- Gate policy at a premature final answer: nudge only while the obligation
is open and the budget remains. -/
def wantsNudge (s : State) (nudges maxNudges : Nat) : Bool :=
  s.unverifiedMutation && decide (nudges < maxNudges)

/-- The premature-final loop as the runtime implements it: each premature
final increments the counter only when the gate wants a nudge. -/
def nudgesAfter (finals : Nat) (s : State) (maxNudges : Nat) : Nat :=
  Nat.rec 0
    (fun _ acc => acc + (if wantsNudge s acc maxNudges then 1 else 0))
    finals

/-- Harmlessness: a session with no realized mutation never opens the
obligation, so the gate never nudges it.  Zig mirror: L2 "disabled gate is
inert" plus the sensor invariant that only `isRealizedMutation` sets
`unverified_mutation`. -/
theorem no_mutation_no_obligation
    (ts : List TurnObservation)
    (h : ∀ t ∈ ts, t.realizedMutation = false) :
    (run ts).unverifiedMutation = false := by
  suffices general :
      ∀ s : State, s.unverifiedMutation = false →
        (ts.foldl step s).unverifiedMutation = false by
    exact general init rfl
  induction ts with
  | nil => intro s hs; simpa [run] using hs
  | cons t rest ih =>
    intro s hs
    have ht : t.realizedMutation = false := h t (List.mem_cons_self ..)
    have hrest : ∀ u ∈ rest, u.realizedMutation = false := fun u hu =>
      h u (List.mem_cons_of_mem _ hu)
    have step_closed : (step s t).unverifiedMutation = false := by
      unfold step
      rw [ht]
      by_cases h12 : (t.tier1 || t.tier2) = true
      · simp [h12]
      · simp only [Bool.not_eq_true] at h12
        by_cases hf : (t.failedAttempt && s.unverifiedMutation) = true
        · simp [h12, hf, hs]
        · simp only [Bool.not_eq_true] at hf
          simp [h12, hf, hs]
    have := ih (fun u hu => hrest u hu) (step s t) step_closed
    simpa [List.foldl_cons] using this

theorem no_mutation_no_nudge
    (ts : List TurnObservation) (nudges maxNudges : Nat)
    (h : ∀ t ∈ ts, t.realizedMutation = false) :
    wantsNudge (run ts) nudges maxNudges = false := by
  unfold wantsNudge
  rw [no_mutation_no_obligation ts h]
  rfl

/-- Bounded actuation: however many premature finals arrive, the nudge
counter never exceeds the budget.  Zig mirror: L2 "exhausted nudges finish
honestly" (MAX_VERIFICATION_NUDGES). -/
theorem nudges_bounded (finals : Nat) (s : State) (maxNudges : Nat) :
    nudgesAfter finals s maxNudges ≤ maxNudges := by
  induction finals with
  | zero => exact Nat.zero_le _
  | succ n ih =>
    unfold nudgesAfter at ih ⊢
    by_cases hw : wantsNudge s (Nat.rec 0
        (fun _ acc => acc + (if wantsNudge s acc maxNudges then 1 else 0)) n)
        maxNudges = true
    · have hlt : Nat.rec 0
          (fun _ acc => acc + (if wantsNudge s acc maxNudges then 1 else 0)) n
          < maxNudges := by
        have := hw
        unfold wantsNudge at this
        exact of_decide_eq_true ((Bool.and_eq_true _ _).mp this).2
      simpa [hw] using hlt
    · simp only [Bool.not_eq_true] at hw
      simpa [hw] using ih

/-- Mutation reopens the obligation and resets negative evidence.  Zig
mirror: unit test "same-turn mutation plus probe keeps the obligation
open" and "failed verification attempts set known_failing" (reset leg). -/
theorem mutate_reopens (s : State) (t : TurnObservation)
    (h : t.realizedMutation = true) :
    (step s t).unverifiedMutation = true ∧ (step s t).knownFailing = false := by
  unfold step
  rw [h]
  exact ⟨rfl, rfl⟩

/-- Any verification tier closes the obligation on a non-mutating turn.
Zig mirror: unit tests "tier-2 heredoc import probe closes the obligation"
and "failed verification attempts ... success clears it". -/
theorem verify_closes (s : State) (t : TurnObservation)
    (hm : t.realizedMutation = false) (hv : (t.tier1 || t.tier2) = true) :
    (step s t).unverifiedMutation = false ∧ (step s t).knownFailing = false := by
  unfold step
  rw [hm, hv]
  exact ⟨rfl, rfl⟩

/-- The churn counter increments exactly on a verified-state mutation.
Zig mirror: unit test "mutation after verified state counts churn and arms
one caution". -/
theorem churn_counts_verified_mutations (s : State) (t : TurnObservation)
    (h : t.realizedMutation = true) :
    (step s t).reopenedAfterVerification =
      s.reopenedAfterVerification +
        (if s.mutationSeen && !s.unverifiedMutation then 1 else 0) := by
  simp [step, h]

/-- Honest negative evidence: whenever `knownFailing` selects the
fix-or-report nudge variant, the obligation really is open — the gate can
never accuse a verified session of a known failure.  Zig mirror: the
known-failing L2 asserts the variant only appears with an unmet
obligation. -/
theorem known_failing_implies_open (ts : List TurnObservation)
    (h : (run ts).knownFailing = true) :
    (run ts).unverifiedMutation = true := by
  have general :
      ∀ (l : List TurnObservation) (s : State),
        (s.knownFailing = true → s.unverifiedMutation = true) →
        ((l.foldl step s).knownFailing = true →
          (l.foldl step s).unverifiedMutation = true) := by
    intro l
    induction l with
    | nil => intro s hs; simpa using hs
    | cons t rest ih =>
      intro s hs
      have preserved :
          (step s t).knownFailing = true →
            (step s t).unverifiedMutation = true := by
        unfold step
        by_cases hm : t.realizedMutation = true
        · rw [hm]; intro hk; cases hk
        · simp only [Bool.not_eq_true] at hm
          rw [hm]
          by_cases h12 : (t.tier1 || t.tier2) = true
          · simp only [h12, if_true, Bool.false_eq_true, if_false]
            intro hk; cases hk
          · simp only [Bool.not_eq_true] at h12
            rw [h12]
            by_cases hf : (t.failedAttempt && s.unverifiedMutation) = true
            · simp only [hf, if_true, Bool.false_eq_true, if_false]
              intro _
              exact ((Bool.and_eq_true _ _).mp hf).2
            · simp only [Bool.not_eq_true] at hf
              rw [hf]
              simpa using hs
      simpa [List.foldl_cons] using ih (step s t) preserved
  exact general ts init (by intro hk; cases hk) h

end MetaCodesControl.VerificationGate
