import Std

/-! # Verdict provenance: authority ordering as governed policy

Native verdict ingestion (`src/core/verdict.zig`) internalizes what the
evaluation adapter used to provide: any pinned check's output becomes a
task-outcome row. The new hazard is authority: a self-run check is
gameable by the agent that wrote it (the equivalence-substitution
campaign lesson), so rows carry a provenance tier and the best-attempt
selector prefers higher tiers at equal reward. The tier lattice and the
selection preference are the policy proven here; parsing and taint
CLASSIFICATION stay engineering (unit tests).

Each theorem names the mirroring Zig test. -/

namespace MetaCodesControl.VerdictProvenance

inductive Tier where
  | selfClaim
  | hostRunTainted
  | hostRun
  | externalOracle
  | user
  deriving Repr, DecidableEq

def rank : Tier → Nat
  | .selfClaim => 0
  | .hostRunTainted => 1
  | .hostRun => 2
  | .externalOracle => 3
  | .user => 4

structure Row where
  reward : Nat -- 万分位定点(0.7273 → 7273):选择只需序,不需实数
  tier : Tier
  recency : Nat
  deriving Repr

/-- `bestHistoryRow` 的偏好谓词:字典序 (reward, tier rank, recency)。 -/
def better (a b : Row) : Bool :=
  if a.reward ≠ b.reward then a.reward > b.reward
  else if rank a.tier ≠ rank b.tier then rank a.tier > rank b.tier
  else a.recency > b.recency

/-- A tainted host run never outranks an untainted one at equal reward.
Zig mirror: "provenance parse + rank order". -/
theorem tainted_never_beats_clean (a b : Row)
    (hr : a.reward = b.reward)
    (ha : a.tier = .hostRunTainted) (hb : b.tier = .hostRun) :
    better a b = false := by
  unfold better
  simp [hr, ha, hb, rank]

/-- A self-run claim never outranks an external oracle at equal reward:
the evaluation verifier's rows keep authority over anything the agent
ran for itself. -/
theorem self_never_beats_oracle (a b : Row)
    (hr : a.reward = b.reward)
    (ha : a.tier = .selfClaim) (hb : b.tier = .externalOracle) :
    better a b = false := by
  unfold better
  simp [hr, ha, hb, rank]

/-- Reward strictly dominates tier: a genuinely better attempt wins even
with the weakest provenance — authority breaks ties, it does not veto
progress. -/
theorem reward_dominates (a b : Row)
    (h : a.reward > b.reward) : better a b = true := by
  unfold better
  have hne : a.reward ≠ b.reward := Nat.ne_of_gt h
  simp [hne, h]

/-- The preference is irreflexive: no row beats itself, so the selector
cannot oscillate between equal candidates. -/
theorem irreflexive (a : Row) : better a a = false := by
  unfold better
  simp

end MetaCodesControl.VerdictProvenance
