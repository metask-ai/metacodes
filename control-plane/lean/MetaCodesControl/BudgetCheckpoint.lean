import MetaCodesControl.ClosedLoop
import MetaCodesControl.DurableAbort

namespace MetaCodesControl.BudgetCheckpoint

open MetaCodesControl.ClosedLoop
open MetaCodesControl.DurableAbort

/-- Budget violations instantiate the repository-wide durable-abort protocol. -/
abbrev ViolationPhase := FailurePhase
abbrev ViolationEvent := FailureEvent

def budgetTransition := MetaCodesControl.DurableAbort.transition
def runBudgetTrace := MetaCodesControl.DurableAbort.runTrace
def canonicalViolationTrace := MetaCodesControl.DurableAbort.canonicalTrace

theorem checkpoint_transition_requires_invalid_mark
    (phase : ViolationPhase) (event : ViolationEvent)
    (committed : budgetTransition phase event = some .checkpointCommitted) :
    phase = .invalidMarked ∧ event = .commitCheckpoint := by
  exact DurableAbort.checkpoint_transition_requires_invalid_mark phase event committed

theorem abort_transition_requires_committed_checkpoint
    (phase : ViolationPhase) (event : ViolationEvent)
    (aborted : budgetTransition phase event = some .aborted) :
    phase = .checkpointCommitted ∧ event = .abort := by
  exact DurableAbort.abort_transition_requires_committed_checkpoint phase event aborted

theorem canonical_budget_violation_trace_aborts :
    runBudgetTrace .observed canonicalViolationTrace = some .aborted := by
  exact DurableAbort.canonical_failure_trace_aborts

theorem abort_before_checkpoint_is_rejected :
    runBudgetTrace .observed [.markInvalid, .abort] = none := by
  exact DurableAbort.abort_before_checkpoint_is_rejected

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
