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
