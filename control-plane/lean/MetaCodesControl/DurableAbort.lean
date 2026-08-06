namespace MetaCodesControl.DurableAbort

/--
The host-observed phases shared by every failure that must be published before
the caller is allowed to abort.  `checkpointCommitted` is deliberately an
external fact: Lean constrains how that fact may be consumed, while the runtime
sensor and L2 tests establish what the storage implementation actually did.
-/
inductive FailurePhase where
  | observed
  | invalidMarked
  | checkpointCommitted
  | aborted
  deriving Repr, DecidableEq

inductive FailureEvent where
  | markInvalid
  | commitCheckpoint
  | abort
  deriving Repr, DecidableEq

def transition : FailurePhase → FailureEvent → Option FailurePhase
  | .observed, .markInvalid => some .invalidMarked
  | .invalidMarked, .commitCheckpoint => some .checkpointCommitted
  | .checkpointCommitted, .abort => some .aborted
  | _, _ => none

def runTrace : FailurePhase → List FailureEvent → Option FailurePhase
  | phase, [] => some phase
  | phase, event :: rest => do
      let next ← transition phase event
      runTrace next rest

def canonicalTrace : List FailureEvent :=
  [.markInvalid, .commitCheckpoint, .abort]

theorem checkpoint_transition_requires_invalid_mark
    (phase : FailurePhase) (event : FailureEvent)
    (committed : transition phase event = some .checkpointCommitted) :
    phase = .invalidMarked ∧ event = .commitCheckpoint := by
  cases phase <;> cases event <;> simp_all [transition]

theorem abort_transition_requires_committed_checkpoint
    (phase : FailurePhase) (event : FailureEvent)
    (aborted : transition phase event = some .aborted) :
    phase = .checkpointCommitted ∧ event = .abort := by
  cases phase <;> cases event <;> simp_all [transition]

theorem canonical_failure_trace_aborts :
    runTrace .observed canonicalTrace = some .aborted := by
  decide

theorem abort_before_checkpoint_is_rejected :
    runTrace .observed [.markInvalid, .abort] = none := by
  decide

theorem abort_without_invalid_mark_is_rejected :
    runTrace .observed [.commitCheckpoint, .abort] = none := by
  decide

end MetaCodesControl.DurableAbort
