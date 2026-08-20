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

end MetaCodesControl.ObligationGate
