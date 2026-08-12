import MetaCodesControl.ClosedLoop
import MetaCodesControl.DurableAbort

namespace MetaCodesControl.TreatmentActivation

open MetaCodesControl.ClosedLoop

/-- Execution-grounded phases of the persistent TinyKG treatment. -/
inductive TreatmentPhase where
  | available
  | created
  | claimed
  | completed
  | storeVerified
  deriving Repr, DecidableEq

inductive TreatmentEvent where
  | createPersistent
  | claimSameTask
  | completeSameTask
  | verifyStore
  deriving Repr, DecidableEq

/--
The scoring contract admits only one ordered persistent lifecycle.  A prompt,
tool declaration, in-memory task, or completed transcript without store readback
cannot reach `storeVerified`.
-/
def transition : TreatmentPhase → TreatmentEvent → Option TreatmentPhase
  | .available, .createPersistent => some .created
  | .created, .claimSameTask => some .claimed
  | .claimed, .completeSameTask => some .completed
  | .completed, .verifyStore => some .storeVerified
  | _, _ => none

def runTrace : TreatmentPhase → List TreatmentEvent → Option TreatmentPhase
  | phase, [] => some phase
  | phase, event :: rest => do
      let next ← transition phase event
      runTrace next rest

def canonicalTrace : List TreatmentEvent :=
  [.createPersistent, .claimSameTask, .completeSameTask, .verifyStore]

def treatmentAdmitted (phase : TreatmentPhase) : Bool :=
  phase == .storeVerified

theorem treatment_admitted_implies_store_verified
    (phase : TreatmentPhase)
    (admitted : treatmentAdmitted phase = true) :
    phase = .storeVerified := by
  simpa [treatmentAdmitted] using admitted

theorem store_verification_requires_completed
    (phase : TreatmentPhase) (event : TreatmentEvent)
    (verified : transition phase event = some .storeVerified) :
    phase = .completed ∧ event = .verifyStore := by
  cases phase <;> cases event <;> simp_all [transition]

theorem canonical_treatment_trace_is_admitted :
    runTrace .available canonicalTrace = some .storeVerified := by
  decide

theorem claim_before_create_is_rejected :
    runTrace .available [.claimSameTask] = none := by
  decide

theorem complete_before_claim_is_rejected :
    runTrace .available [.createPersistent, .completeSameTask] = none := by
  decide

theorem completion_without_store_readback_is_not_admitted :
    treatmentAdmitted .completed = false := by
  decide

/-- Baseline evidence is admitted only when every persistent surface is absent. -/
structure BaselineFacts where
  kgToolCall : Bool
  persistentCreate : Bool
  kgTaskUpdate : Bool
  storePresent : Bool
  deriving Repr, DecidableEq

def baselineAdmitted (facts : BaselineFacts) : Bool :=
  !facts.kgToolCall &&
  !facts.persistentCreate &&
  !facts.kgTaskUpdate &&
  !facts.storePresent

theorem baseline_admitted_implies_persistent_lifecycle_absent
    (facts : BaselineFacts)
    (admitted : baselineAdmitted facts = true) :
    facts.kgToolCall = false ∧
    facts.persistentCreate = false ∧
    facts.kgTaskUpdate = false ∧
    facts.storePresent = false := by
  simp [baselineAdmitted] at admitted
  simpa [and_assoc] using admitted

/--
A failed treatment attestation uses the same host-observed durable-abort
protocol as a budget violation.  These theorems constrain the abstract event
trace; repository sensors and L2 tests must still bind `commitCheckpoint` to a
real successful checkpoint publication.
-/
theorem treatment_failure_checkpoint_requires_invalid_mark
    (phase : DurableAbort.FailurePhase) (event : DurableAbort.FailureEvent)
    (committed : DurableAbort.transition phase event = some .checkpointCommitted) :
    phase = .invalidMarked ∧ event = .commitCheckpoint := by
  exact DurableAbort.checkpoint_transition_requires_invalid_mark phase event committed

theorem treatment_failure_abort_requires_committed_checkpoint
    (phase : DurableAbort.FailurePhase) (event : DurableAbort.FailureEvent)
    (aborted : DurableAbort.transition phase event = some .aborted) :
    phase = .checkpointCommitted ∧ event = .abort := by
  exact DurableAbort.abort_transition_requires_committed_checkpoint phase event aborted

theorem treatment_failure_abort_before_checkpoint_is_rejected :
    DurableAbort.runTrace .observed [.markInvalid, .abort] = none := by
  exact DurableAbort.abort_before_checkpoint_is_rejected

/-- Eight repository obligations bind the model to the real execution path. -/
def treatmentActivationSignal
    (topology : Topology) (observation : Observation) : Signal :=
  if observation.declared == 8 then signal topology observation else .blockRelease

def treatmentActivationNextState
    (topology : Topology) (observation : Observation) : RuleState :=
  match treatmentActivationSignal topology observation with
  | .blockRelease => .blocked
  | .runFeedback => .verifying
  | .admitRelease => .compliant

def treatmentActivationReleaseAllowed
    (topology : Topology) (observation : Observation) : Bool :=
  treatmentActivationSignal topology observation == .admitRelease

theorem treatment_activation_admitted_implies_eight_obligations
    (topology : Topology) (observation : Observation)
    (admitted : treatmentActivationReleaseAllowed topology observation = true) :
    observation.declared = 8 ∧ observation.covered = 8 := by
  simp [treatmentActivationReleaseAllowed, treatmentActivationSignal] at admitted
  split at admitted
  · rename_i declaredEight
    have genericAdmitted : releaseAllowed topology observation = true := by
      simpa [releaseAllowed] using admitted
    have exact := admitted_implies_zero_deviation topology observation genericAdmitted
    omega
  · simp at admitted

theorem treatment_activation_missing_obligation_blocks
    (topology : Topology) (observation : Observation)
    (declaresEight : observation.declared = 8)
    (missing : observation.covered < 8) :
    treatmentActivationSignal topology observation = .blockRelease := by
  simp [treatmentActivationSignal, declaresEight]
  apply missing_evidence_blocks topology observation
  omega

theorem treatment_activation_wrong_cardinality_blocks
    (topology : Topology) (observation : Observation)
    (wrong : observation.declared ≠ 8) :
    treatmentActivationSignal topology observation = .blockRelease := by
  simp [treatmentActivationSignal, wrong]

end MetaCodesControl.TreatmentActivation
