import Std

/-! # Task-scoped closure obligations: formal policy

The runtime (`src/core/obligation_gate.zig`) carries obligations the
rule-author learned for one concrete task in a previous attempt (the dynamic
layer is *allowed* to fit its environment; the static layer stays frozen and
task-agnostic). Actuation is deliberately weaker than the project-rule
kernel: observing an executed Bash command whose text contains the
obligation's needle marks it met, and a premature final answer earns at most
one bounded reminder per obligation inside a global budget — never a denial.

The Zig `Runtime.decide` walks the obligation array and returns the first
index that is neither met nor nudged, gated by the budget. The policy is
element-wise; the element predicate and the budget gate are proven here.

Each theorem names the mirroring Zig test. -/

namespace MetaCodesControl.ObligationGate

def maxNudges : Nat := 3

structure Item where
  met : Bool
  nudged : Bool
  deriving Repr, DecidableEq

/-- Element predicate of `Runtime.decide`: an item is selectable iff it is
neither met nor nudged. -/
def selectable (item : Item) : Bool :=
  !item.met && !item.nudged

/-- Budget gate of `Runtime.decide`: with the budget exhausted no index is
returned regardless of item state. -/
def decide (item : Item) (nudgesUsed : Nat) : Bool :=
  if nudgesUsed ≥ maxNudges then false else selectable item

/-- A satisfied obligation is never selected.  Zig mirror: "observed command
satisfies the obligation and disarms the nudge". -/
theorem met_never_selected (item : Item) (nudges : Nat)
    (hm : item.met = true) : decide item nudges = false := by
  unfold decide selectable
  by_cases hb : nudges ≥ maxNudges
  · simp [hb]
  · simp [hb, hm]

/-- A nudged obligation is never selected again (per-obligation one-shot).
Zig mirror: "each obligation nudges at most once and the budget is
global". -/
theorem per_obligation_one_shot (item : Item) (nudges : Nat)
    (hn : item.nudged = true) : decide item nudges = false := by
  unfold decide selectable
  by_cases hb : nudges ≥ maxNudges
  · simp [hb]
  · simp [hb, hn]

/-- Exhausted budget decides nothing, whatever the item state.  Zig mirror:
"each obligation nudges at most once and the budget is global" (tail
assertion). -/
theorem budget_bound (item : Item) (nudges : Nat)
    (h : nudges ≥ maxNudges) : decide item nudges = false := by
  unfold decide
  simp [h]

/-- `noteNudged` marks the item and spends budget: selection strictly
decreases — the same item can never be decided twice.  Composition of
`per_obligation_one_shot` over the runtime's bookkeeping. -/
theorem nudge_then_never_again (item : Item) (nudges : Nat) :
    decide { item with nudged := true } (nudges + 1) = false := by
  exact per_obligation_one_shot _ _ rfl

/-- Success-conditioned satisfaction (v2): a result event can only set
`met`, never clear it — once an obligation is satisfied by an observed
successful execution it stays satisfied, whatever later events arrive.
Zig mirror: "only a successful execution satisfies the obligation"
(tail assertion). -/
def afterResult (item : Item) (matched success : Bool) : Item :=
  { item with met := item.met || (matched && success) }

theorem met_monotone (item : Item) (matched success : Bool)
    (h : item.met = true) : (afterResult item matched success).met = true := by
  unfold afterResult
  simp [h]

/-- A failed execution never satisfies: with `met` clear and success false,
the item stays unsatisfied — running the command is not compliance,
succeeding is. -/
theorem failure_never_satisfies (item : Item) (matched : Bool)
    (h : item.met = false) :
    (afterResult item matched false).met = false := by
  unfold afterResult
  simp [h]

/-- Solved quiescence, v35: silence swaps the needle, it does not close the
channel. Stale pending obligations never load on ever-solved work (the
ratchet still releases — p33: stale author obligations on an all-green task
pushed the agent into fixing ghosts, 1.0 → 0.5). But the imperative channel
stays open for at most one reproduce-best artifact directive (p35: with a
zero-needle silence, a conflicting stored memory outweighed the note at
action time — the model recited the proven module path in thinking, then
wrote the stale correction instead; 0.2727 wall regression). `artifact` is
the number of artifact-path directives derivable from the best verdict
(0 when the best row carries no artifact). -/
def loadCount (solved : Bool) (pending artifact : Nat) : Nat :=
  if solved then min artifact 1 else pending

/-- Solved work never loads stale pending obligations — the load is bounded
by the single reproduce-best directive regardless of pending count. -/
theorem solved_never_loads_stale (pending artifact : Nat) :
    loadCount true pending artifact ≤ 1 := by
  simpa [loadCount] using Nat.min_le_right artifact 1

/-- Solved work with no derivable artifact is truly silent. -/
theorem solved_without_artifact_is_silent (pending : Nat) :
    loadCount true pending 0 = 0 := by rfl

/-- Solved work with a derivable artifact loads exactly the one
reproduce-best directive — the imperative channel does not close. -/
theorem solved_swaps_needle (pending artifact : Nat) (h : 1 ≤ artifact) :
    loadCount true pending artifact = 1 := by
  simp [loadCount, Nat.min_eq_right h]

/-- The load on solved work is independent of how many stale obligations
are pending — poison cannot re-enter through volume. -/
theorem solved_load_ignores_pending (p q artifact : Nat) :
    loadCount true p artifact = loadCount true q artifact := by rfl

theorem unsolved_keeps_ratchet (pending artifact : Nat) :
    loadCount false pending artifact = pending := by rfl

/-- v36 stuck-plateau cooling: when reward and the failing set have been
byte-identical for the last three attempts under the full pressure playbook,
the playbook is proven non-causal on this task — the nudge budget drops to
one (p36: the permanently-stuck task consumed the largest request share of
the batch at a flat reward). Any new evidence — a reward change, a
failing-set change, a fresh needle from a new mechanism — breaks the plateau
key and restores full pressure, so a breakthrough dose is never cooled
away. -/
def nudgeBudget (plateau : Bool) : Nat :=
  if plateau then 1 else maxNudges

theorem plateau_caps_pressure : nudgeBudget true = 1 := by rfl

theorem fresh_evidence_restores : nudgeBudget false = maxNudges := by rfl

/-- Cooling never closes the channel entirely: even on a plateau one nudge
remains available. -/
theorem cooled_channel_stays_open (plateau : Bool) : 1 ≤ nudgeBudget plateau := by
  cases plateau <;> simp [nudgeBudget, maxNudges]

/-- v41 needle-efficacy fold: retirement is provably loss-free in both rules.
Rule A (inert): a needle nudged in at least `k` rounds that the model never
once dispatched is behaviorally inert — retiring it cannot lose progress the
model was never going to make. A mechanism evolution that changes the
needle's reason mints a fresh candidate id, so history-proven breakthrough
needles (etag) restart their count under a new identity and are never
swept. Rule B (non-causal): a needle that was satisfied in some round with
no reward gain in or after that round is proven non-causal for this task —
its satisfaction does not move the score. -/
def inertRetire (k nudgeRounds dispatchRounds : Nat) : Bool :=
  if k ≤ nudgeRounds ∧ dispatchRounds = 0 then true else false

def nonCausalRetire (metRounds : Nat) (gainAfterMet : Bool) : Bool :=
  if 1 ≤ metRounds ∧ gainAfterMet = false then true else false

/-- A needle the model ever acted on is never inert-retired — compliance is
absolute protection under Rule A. -/
theorem dispatched_never_inert (k n d : Nat) (h : 1 ≤ d) :
    inertRetire k n d = false := by
  unfold inertRetire
  rw [if_neg]
  rintro ⟨_, hd⟩
  omega

/-- Below the nudge threshold nothing retires — young needles are safe. -/
theorem under_threshold_never_inert (k n d : Nat) (h : n < k) :
    inertRetire k n d = false := by
  unfold inertRetire
  rw [if_neg]
  rintro ⟨hk, _⟩
  omega

/-- Any reward gain after compliance protects the needle under Rule B. -/
theorem gain_protects (m : Nat) : nonCausalRetire m true = false := by
  unfold nonCausalRetire
  rw [if_neg]
  rintro ⟨_, hg⟩
  exact absurd hg (by simp)

/-- A never-satisfied needle is never non-causal-retired — Rule B only
judges needles whose satisfaction was actually observed. -/
theorem unmet_never_noncausal (g : Bool) : nonCausalRetire 0 g = false := by
  unfold nonCausalRetire
  rw [if_neg]
  rintro ⟨hm, _⟩
  omega

/-! ## v43 reproduce-mode self-invalidation

Solved quiescence (v35) presupposes that the claimed best is reproducible.
p44b/p45 forensics: a claimed-1.0 artifact replayed byte-identically to
0.4545 for two rounds — the artifact channel had dropped the modified-file
wiring hunks, while quiescence kept refusing every pressure needle: a
self-locking plateau. The claim is invalidated when the tail of the task's
history shows `reproGrace` consecutive unsolved rounds after a solved row;
the first regression keeps quiescence (one REGRESSED replay chance). An
invalidated claim also suspends retirement Rule B: the telemetry `best`
field carries the unreproducible claim, and judging "no gain" against it
would retire the historically proven breakthrough needle. -/

def reproGrace : Nat := 2

/-- Claim invalidation: a solved row **carrying an artifact** exists and the
trailing failure streak has exhausted the grace budget.  Artifact-backed
claims are mechanically replayable — two failed replays are empirical proof
of unreproducibility.  Textual claims (no artifact) keep v35 semantics:
re-pressuring a proven task only chases regression ghosts (p33). -/
def claimInvalidated (solvedWithArtifact : Bool) (failStreak : Nat) : Bool :=
  solvedWithArtifact && Nat.ble reproGrace failStreak

/-- A claim without an artifact never invalidates, whatever the streak —
the v35 quiescence for textual claims is preserved verbatim.  Zig mirror:
cap-task pin ("solved without artifact stays truly silent"). -/
theorem textual_claim_never_invalidates (k : Nat) :
    claimInvalidated false k = false := by rfl

/-- The first regression after a solved round keeps quiescence — the
REGRESSED replay directive gets one chance before pressure returns.
Zig mirror: "one regression keeps the replay grace". -/
theorem one_regression_keeps_grace (s : Bool) :
    claimInvalidated s 1 = false := by
  cases s <;> rfl

/-- Two consecutive unreproduced rounds invalidate the claim.
Zig mirror: "two failed replays restore the pressure stack". -/
theorem invalidated_restores_pressure :
    claimInvalidated true 2 = true := by rfl

/-- Quiescence holds only while the claim stands. -/
def quiesce (everSolved claimInvalid : Bool) : Bool :=
  everSolved && !claimInvalid

theorem invalid_claim_never_quiesces (es : Bool) :
    quiesce es true = false := by
  cases es <;> rfl

theorem valid_claim_keeps_quiescence :
    quiesce true false = true := by rfl

/-- Rule B applies only under a standing claim: with the claim invalidated,
"met with no gain" is not evidence — the recorded best is the very value
that failed to reproduce. -/
def ruleBRetire (claimValid met noGain : Bool) : Bool :=
  claimValid && met && noGain

theorem invalid_claim_never_retires (m g : Bool) :
    ruleBRetire false m g = false := by rfl

theorem standing_claim_keeps_rule_b :
    ruleBRetire true true true = true := by rfl

end MetaCodesControl.ObligationGate

