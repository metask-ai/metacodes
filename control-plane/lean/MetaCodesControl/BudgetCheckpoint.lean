import MetaCodesControl.ClosedLoop

namespace MetaCodesControl.BudgetCheckpoint

open MetaCodesControl.ClosedLoop

/-- The only legal phases after runtime budget telemetry reports a violation. -/
inductive ViolationPhase where
  | observed
  | invalidMarked
  | checkpointCommitted
  | aborted
  deriving Repr, DecidableEq

inductive ViolationEvent where
  | markInvalid
  | commitCheckpoint
  | abort
  deriving Repr, DecidableEq

/--
The transition relation makes the durability order executable.  In particular,
`abort` has no transition from `observed` or `invalidMarked`, and checkpoint
publication has no transition before the invalid marker exists.
-/
def transition : ViolationPhase → ViolationEvent → Option ViolationPhase
  | .observed, .markInvalid => some .invalidMarked
  | .invalidMarked, .commitCheckpoint => some .checkpointCommitted
  | .checkpointCommitted, .abort => some .aborted
  | _, _ => none

def runTrace : ViolationPhase → List ViolationEvent → Option ViolationPhase
  | phase, [] => some phase
  | phase, event :: rest => do
      let next ← transition phase event
      runTrace next rest

def canonicalViolationTrace : List ViolationEvent :=
  [.markInvalid, .commitCheckpoint, .abort]

theorem checkpoint_transition_requires_invalid_mark
    (phase : ViolationPhase) (event : ViolationEvent)
    (committed : transition phase event = some .checkpointCommitted) :
    phase = .invalidMarked ∧ event = .commitCheckpoint := by
  cases phase <;> cases event <;> simp_all [transition]

theorem abort_transition_requires_committed_checkpoint
    (phase : ViolationPhase) (event : ViolationEvent)
    (aborted : transition phase event = some .aborted) :
    phase = .checkpointCommitted ∧ event = .abort := by
  cases phase <;> cases event <;> simp_all [transition]

theorem canonical_budget_violation_trace_aborts :
    runTrace .observed canonicalViolationTrace = some .aborted := by
  decide

theorem abort_before_checkpoint_is_rejected :
    runTrace .observed [.markInvalid, .abort] = none := by
  decide

/--
The repository slice has six independently observed links: fixed arm-neutral
caps, whole-schedule capacity before network, sealed-cap usage validation,
invalid marking before publication, durable publication before abort, and
promotion-time revalidation.  The cardinality is part of the kernel so a
weakened sensor cannot redefine its surviving subset as complete.
-/
def evalBudgetSignal
    (topology : Topology) (observation : Observation) : Signal :=
  if observation.declared == 6 then signal topology observation else .blockRelease

def evalBudgetNextState
    (topology : Topology) (observation : Observation) : RuleState :=
  match evalBudgetSignal topology observation with
  | .blockRelease => .blocked
  | .runFeedback => .verifying
  | .admitRelease => .compliant

def evalBudgetReleaseAllowed
    (topology : Topology) (observation : Observation) : Bool :=
  evalBudgetSignal topology observation == .admitRelease

theorem eval_budget_admitted_implies_six_obligations
    (topology : Topology) (observation : Observation)
    (admitted : evalBudgetReleaseAllowed topology observation = true) :
    observation.declared = 6 ∧ observation.covered = 6 := by
  simp [evalBudgetReleaseAllowed, evalBudgetSignal] at admitted
  split at admitted
  · rename_i declaredSix
    have genericAdmitted : releaseAllowed topology observation = true := by
      simpa [releaseAllowed] using admitted
    have exact := admitted_implies_zero_deviation topology observation genericAdmitted
    omega
  · simp at admitted

theorem eval_budget_missing_obligation_blocks
    (topology : Topology) (observation : Observation)
    (declaresSix : observation.declared = 6)
    (missing : observation.covered < 6) :
    evalBudgetSignal topology observation = .blockRelease := by
  simp [evalBudgetSignal, declaresSix]
  apply missing_evidence_blocks topology observation
  omega

theorem eval_budget_wrong_cardinality_blocks
    (topology : Topology) (observation : Observation)
    (wrong : observation.declared ≠ 6) :
    evalBudgetSignal topology observation = .blockRelease := by
  simp [evalBudgetSignal, wrong]

end MetaCodesControl.BudgetCheckpoint
