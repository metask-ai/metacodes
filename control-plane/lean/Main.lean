import MetaCodesControl

open MetaCodesControl.ClosedLoop

def parseBool? : String → Option Bool
  | "true" => some true
  | "false" => some false
  | _ => none

def parseFeedback? : String → Option FeedbackStatus
  | "pending" => some .pending
  | "passed" => some .passed
  | "failed" => some .failed
  | _ => none

def boolJson (value : Bool) : String := if value then "true" else "false"

def feedbackName : FeedbackStatus → String
  | .pending => "pending"
  | .passed => "passed"
  | .failed => "failed"

def signalName : Signal → String
  | .blockRelease => "block_release"
  | .runFeedback => "run_feedback"
  | .admitRelease => "admit_release"

def stateName : RuleState → String
  | .blocked => "blocked"
  | .verifying => "verifying"
  | .compliant => "compliant"

def usage : String :=
  "rule-decision RULE_ID TARGET SENSOR DECISION ACTUATOR FEEDBACK COUNTEREXAMPLE SENSOR_OK DECLARED COVERED FEEDBACK_STATUS"

def main (args : List String) : IO UInt32 := do
  match args with
  | [ruleId, targetText, sensorText, decisionText, actuatorText, feedbackText,
      counterexampleText, sensorOkText, declaredText, coveredText, feedbackStatusText] =>
      let parsed := do
        let target ← parseBool? targetText
        let sensor ← parseBool? sensorText
        let decision ← parseBool? decisionText
        let actuator ← parseBool? actuatorText
        let feedback ← parseBool? feedbackText
        let counterexample ← parseBool? counterexampleText
        let sensorOk ← parseBool? sensorOkText
        let declared ← declaredText.toNat?
        let covered ← coveredText.toNat?
        let feedbackStatus ← parseFeedback? feedbackStatusText
        pure (target, sensor, decision, actuator, feedback, counterexample,
          sensorOk, declared, covered, feedbackStatus)
      match parsed with
      | none =>
          IO.eprintln s!"invalid arguments: {usage}"
          pure 64
      | some (target, sensor, decision, actuator, feedback, counterexample,
          sensorOk, declared, covered, feedbackStatus) =>
          let topology : Topology := {
            target, sensor, decision, actuator, feedback, counterexample
          }
          let observation : Observation := {
            sensorOk, declared, covered, feedback := feedbackStatus
          }
          let executionOntologyRule := ruleId == "ontology.execution-grounded-projection.l2"
          let controlSignal := if executionOntologyRule then
            executionProjectionSignal topology observation
          else
            signal topology observation
          let state := if executionOntologyRule then
            executionProjectionNextState topology observation
          else
            nextState topology observation
          let allowed := if executionOntologyRule then
            executionProjectionReleaseAllowed topology observation
          else
            releaseAllowed topology observation
          IO.println <|
            "{" ++
            "\"schema_version\":1," ++
            "\"rule_id\":\"" ++ ruleId ++ "\"," ++
            "\"closed_loop\":" ++ boolJson topology.complete ++ "," ++
            "\"sensor_ok\":" ++ boolJson observation.sensorOk ++ "," ++
            "\"declared\":" ++ toString observation.declared ++ "," ++
            "\"covered\":" ++ toString observation.covered ++ "," ++
            "\"deviation\":" ++ toString observation.deviation ++ "," ++
            "\"feedback\":\"" ++ feedbackName observation.feedback ++ "\"," ++
            "\"signal\":\"" ++ signalName controlSignal ++ "\"," ++
            "\"state\":\"" ++ stateName state ++ "\"," ++
            "\"release_allowed\":" ++ boolJson allowed ++
            "}"
          pure 0
  | _ =>
      IO.eprintln usage
      pure 64
