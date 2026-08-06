import Std

namespace MetaCodesControl.ClosedLoop

/-- The six links that make a repository rule an actual feedback loop. -/
structure Topology where
  target : Bool
  sensor : Bool
  decision : Bool
  actuator : Bool
  feedback : Bool
  counterexample : Bool
  deriving Repr, DecidableEq

def Topology.complete (topology : Topology) : Bool :=
  topology.target && topology.sensor && topology.decision &&
    topology.actuator && topology.feedback && topology.counterexample

inductive FeedbackStatus where
  | pending
  | passed
  | failed
  deriving Repr, DecidableEq

/-- Facts are produced by repository sensors; Lean never guesses source facts. -/
structure Observation where
  sensorOk : Bool
  declared : Nat
  covered : Nat
  feedback : FeedbackStatus
  deriving Repr, DecidableEq

def Observation.exact (observation : Observation) : Bool :=
  observation.declared == observation.covered

def Observation.deviation (observation : Observation) : Nat :=
  observation.declared - observation.covered

inductive Signal where
  | blockRelease
  | runFeedback
  | admitRelease
  deriving Repr, DecidableEq

inductive RuleState where
  | blocked
  | verifying
  | compliant
  deriving Repr, DecidableEq

/--
The executable controller. A complete topology and a zero-deviation sensor
observation may start feedback. Release is admitted only after feedback passes.
-/
def signal (topology : Topology) (observation : Observation) : Signal :=
  if !topology.complete || !observation.sensorOk || !observation.exact then
    .blockRelease
  else
    match observation.feedback with
    | .pending => .runFeedback
    | .passed => .admitRelease
    | .failed => .blockRelease

def nextState (topology : Topology) (observation : Observation) : RuleState :=
  match signal topology observation with
  | .blockRelease => .blocked
  | .runFeedback => .verifying
  | .admitRelease => .compliant

def releaseAllowed (topology : Topology) (observation : Observation) : Bool :=
  signal topology observation == .admitRelease

/-- Runtime decision for the execution-grounded ontology slice. Its three
obligations are part of the decision function, so a weakened sensor reporting
2/2 cannot redefine success by silently shrinking the controlled surface. -/
def executionProjectionSignal
    (topology : Topology) (observation : Observation) : Signal :=
  if observation.declared == 3 then signal topology observation else .blockRelease

def executionProjectionNextState
    (topology : Topology) (observation : Observation) : RuleState :=
  match executionProjectionSignal topology observation with
  | .blockRelease => .blocked
  | .runFeedback => .verifying
  | .admitRelease => .compliant

def executionProjectionReleaseAllowed
    (topology : Topology) (observation : Observation) : Bool :=
  executionProjectionSignal topology observation == .admitRelease

/-- The experience-feedback slice has five non-substitutable runtime links:
task-only exact retrieval, lifecycle/evidence governance, pre-work result
actuation, the model-side bounded semantic-expansion contract required by a
non-vector store, and focused real-TinyKG/provider feedback. A weakened adapter
cannot redefine 4/4 as success after silently removing one of them. -/
def experienceFeedbackSignal
    (topology : Topology) (observation : Observation) : Signal :=
  if observation.declared == 5 then signal topology observation else .blockRelease

def experienceFeedbackNextState
    (topology : Topology) (observation : Observation) : RuleState :=
  match experienceFeedbackSignal topology observation with
  | .blockRelease => .blocked
  | .runFeedback => .verifying
  | .admitRelease => .compliant

def experienceFeedbackReleaseAllowed
    (topology : Topology) (observation : Observation) : Bool :=
  experienceFeedbackSignal topology observation == .admitRelease

/-- The build/test throughput slice has seven non-substitutable obligations:
per-test diagnostics, deterministic sharding, fail-closed aggregation, exact
source inventory, explicit fast/full build paths, a location-independent
TinyKG binary, and a reproducible formal artifact identity whose per-build
receipt is not part of the experiment treatment.  Fixing the cardinality
here prevents a weakened repository sensor from calling its surviving subset
complete after an optimization silently removes a coverage guard. -/
def buildTestSignal
    (topology : Topology) (observation : Observation) : Signal :=
  if observation.declared == 7 then signal topology observation else .blockRelease

def buildTestNextState
    (topology : Topology) (observation : Observation) : RuleState :=
  match buildTestSignal topology observation with
  | .blockRelease => .blocked
  | .runFeedback => .verifying
  | .admitRelease => .compliant

def buildTestReleaseAllowed
    (topology : Topology) (observation : Observation) : Bool :=
  buildTestSignal topology observation == .admitRelease

/-- An admitted rule can never be a formalization orphan. -/
theorem admitted_implies_closed_loop
    (topology : Topology) (observation : Observation)
    (admitted : releaseAllowed topology observation = true) :
    topology.complete = true := by
  simp [releaseAllowed, signal] at admitted
  split at admitted <;> simp_all

/-- An admitted rule has no missing or surplus evidence. -/
theorem admitted_implies_zero_deviation
    (topology : Topology) (observation : Observation)
    (admitted : releaseAllowed topology observation = true) :
    observation.declared = observation.covered := by
  simp [releaseAllowed, signal, Observation.exact] at admitted
  split at admitted <;> simp_all

/-- Passing formal topology and static evidence is insufficient without feedback. -/
theorem admitted_implies_feedback_passed
    (topology : Topology) (observation : Observation)
    (admitted : releaseAllowed topology observation = true) :
    observation.feedback = .passed := by
  simp [releaseAllowed, signal] at admitted
  split at admitted <;> simp_all
  cases h : observation.feedback <;> simp [h] at admitted ⊢

/-- Missing evidence blocks both actuation and release. -/
theorem missing_evidence_blocks
    (topology : Topology) (observation : Observation)
    (missing : observation.covered < observation.declared) :
    signal topology observation = .blockRelease := by
  simp [signal, Observation.exact]
  omega

/-- The execution-grounded ontology loop has three independently observed
links: successful execution sensing, terminal projection, and focused L2
feedback. Admission proves that all three—not merely a prose declaration—were
covered by the repository sensor. -/
theorem execution_projection_admitted_implies_three_obligations
    (topology : Topology) (observation : Observation)
    (admitted : executionProjectionReleaseAllowed topology observation = true) :
    observation.declared = 3 ∧ observation.covered = 3 := by
  simp [executionProjectionReleaseAllowed, executionProjectionSignal] at admitted
  split at admitted
  · rename_i declaredThree
    have genericAdmitted : releaseAllowed topology observation = true := by
      simpa [releaseAllowed] using admitted
    have exact := admitted_implies_zero_deviation topology observation genericAdmitted
    omega
  · simp at admitted

/-- With the execution ontology sensor fixed at three obligations, losing any
one executable link blocks before feedback can masquerade as compliance. -/
theorem execution_projection_missing_obligation_blocks
    (topology : Topology) (observation : Observation)
    (declaresThree : observation.declared = 3)
    (missing : observation.covered < 3) :
    signal topology observation = .blockRelease := by
  apply missing_evidence_blocks topology observation
  omega

/-- Shrinking the sensor's declaration count is itself a release-blocking
fault, even when the weakened adapter reports full internal coverage. -/
theorem execution_projection_wrong_cardinality_blocks
    (topology : Topology) (observation : Observation)
    (wrong : observation.declared ≠ 3) :
    executionProjectionSignal topology observation = .blockRelease := by
  simp [executionProjectionSignal, wrong]

/-- Admission of historical execution feedback proves that all five observed
links are still present, not merely that the surviving subset is internally
consistent. -/
theorem experience_feedback_admitted_implies_five_obligations
    (topology : Topology) (observation : Observation)
    (admitted : experienceFeedbackReleaseAllowed topology observation = true) :
    observation.declared = 5 ∧ observation.covered = 5 := by
  simp [experienceFeedbackReleaseAllowed, experienceFeedbackSignal] at admitted
  split at admitted
  · rename_i declaredFive
    have genericAdmitted : releaseAllowed topology observation = true := by
      simpa [releaseAllowed] using admitted
    have exact := admitted_implies_zero_deviation topology observation genericAdmitted
    omega
  · simp at admitted

theorem experience_feedback_missing_obligation_blocks
    (topology : Topology) (observation : Observation)
    (declaresFive : observation.declared = 5)
    (missing : observation.covered < 5) :
    experienceFeedbackSignal topology observation = .blockRelease := by
  simp [experienceFeedbackSignal, declaresFive]
  apply missing_evidence_blocks topology observation
  omega

theorem experience_feedback_wrong_cardinality_blocks
    (topology : Topology) (observation : Observation)
    (wrong : observation.declared ≠ 5) :
    experienceFeedbackSignal topology observation = .blockRelease := by
  simp [experienceFeedbackSignal, wrong]

/-- Admission proves that all seven throughput-integrity obligations were
observed and survived real test feedback; wall-clock speed alone is never a
substitute for coverage or leak/failure semantics. -/
theorem build_test_admitted_implies_seven_obligations
    (topology : Topology) (observation : Observation)
    (admitted : buildTestReleaseAllowed topology observation = true) :
    observation.declared = 7 ∧ observation.covered = 7 := by
  simp [buildTestReleaseAllowed, buildTestSignal] at admitted
  split at admitted
  · rename_i declaredSeven
    have genericAdmitted : releaseAllowed topology observation = true := by
      simpa [releaseAllowed] using admitted
    have exact := admitted_implies_zero_deviation topology observation genericAdmitted
    omega
  · simp at admitted

theorem build_test_missing_obligation_blocks
    (topology : Topology) (observation : Observation)
    (declaresSeven : observation.declared = 7)
    (missing : observation.covered < 7) :
    buildTestSignal topology observation = .blockRelease := by
  simp [buildTestSignal, declaresSeven]
  apply missing_evidence_blocks topology observation
  omega

theorem build_test_wrong_cardinality_blocks
    (topology : Topology) (observation : Observation)
    (wrong : observation.declared ≠ 7) :
    buildTestSignal topology observation = .blockRelease := by
  simp [buildTestSignal, wrong]

/-- A theorem with any missing loop link cannot reach the compliant state. -/
theorem orphan_cannot_be_compliant
    (topology : Topology) (observation : Observation)
    (orphan : topology.complete = false) :
    nextState topology observation = .blocked := by
  simp [nextState, signal, orphan]

/-- A manifest cannot claim an actuator into existence: the repository sensor
must observe the executable build/CI link before release can be admitted. -/
theorem unobserved_actuator_blocks
    (topology : Topology) (observation : Observation)
    (missing : topology.actuator = false) :
    nextState topology observation = .blocked := by
  simp [nextState, signal, Topology.complete, missing]

/-- Failed runtime feedback always drives the controller back to blocked. -/
theorem failed_feedback_blocks
    (topology : Topology) (observation : Observation)
    (failed : observation.feedback = .failed) :
    nextState topology observation = .blocked := by
  simp [nextState, signal, failed]

/-- Missing or malformed telemetry can never be interpreted as compliance. -/
theorem sensor_failure_blocks
    (topology : Topology) (observation : Observation)
    (failed : observation.sensorOk = false) :
    nextState topology observation = .blocked := by
  simp [nextState, signal, failed]

end MetaCodesControl.ClosedLoop
