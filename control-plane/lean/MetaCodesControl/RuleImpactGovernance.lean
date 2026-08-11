import MetaCodesControl.FormalKernel

namespace MetaCodesControl.RuleImpactGovernance

open MetaCodesControl.FormalKernel

set_option maxRecDepth 4096

def requestSchema : String := "metacodes-rule-impact-governance-request-v1"
def verdictSchema : String := "metacodes-rule-impact-governance-verdict-v1"
def checkerVersion : String := "metacodes-project-harness-kernel-v3"
def zeroSha256 : String := "0000000000000000000000000000000000000000000000000000000000000000"

inductive Operation where
  | promote
  | demote
  | quarantine
  deriving Repr, BEq, DecidableEq

inductive RuleState where
  | shadowed
  | promoted
  | quarantined
  deriving Repr, BEq, DecidableEq

structure ImpactFacts where
  completedRun : Bool
  evidenceAuthenticated : Bool
  windowOccurrences : Nat
  formalDecisions : Nat
  formalFaults : Nat
  exposures : Nat
  admits : Nat
  blocks : Nat
  faults : Nat
  shadowDivergences : Nat
  taskSuccess : Bool
  trustworthySuccess : Bool
  driftDetected : Bool
  falseInterventions : Nat
  regressions : Nat
  physicalCheckerCalls : Nat
  checkerElapsedNs : Nat
  providerRequests : Nat
  inputTokens : Nat
  outputTokens : Nat
  cacheReadTokens : Nat
  cacheWriteTokens : Nat
  meteredTokens : Nat
  costMicrousd : Nat
  wallElapsedNs : Nat
  deriving Repr, BEq

structure Policy where
  minExposures : Nat
  maxFormalFaults : Nat
  maxShadowDivergences : Nat
  maxFalseInterventions : Nat
  maxRegressions : Nat
  maxProviderRequests : Nat
  maxMeteredTokens : Nat
  maxCostMicrousd : Nat
  maxWallElapsedNs : Nat
  deriving Repr, BEq

structure Request where
  schemaVersion : String
  requestId : String
  operation : Operation
  expectedCheckerVersion : String
  kernelSha256 : String
  candidateId : String
  projectSha256 : String
  issuerSha256 : String
  bundleSha256 : String
  bundleRevision : Nat
  currentState : RuleState
  sourceIntervalSha256 : String
  labelReceiptSha256 : String
  outcomeEvidenceSha256 : String
  usageEvidenceSha256 : String
  facts : ImpactFacts
  policy : Policy
  deriving Repr, BEq

def nonzeroHex (value : String) : Bool :=
  validLowerHex64 value && value != zeroSha256

def bindingsValid (request : Request) : Bool :=
  request.schemaVersion == requestSchema &&
  request.expectedCheckerVersion == checkerVersion &&
  nonzeroHex request.requestId && nonzeroHex request.kernelSha256 &&
  nonzeroHex request.candidateId && nonzeroHex request.projectSha256 &&
  nonzeroHex request.issuerSha256 && nonzeroHex request.bundleSha256 &&
  request.bundleRevision > 0

def evidenceValid (request : Request) : Bool :=
  request.facts.completedRun && request.facts.evidenceAuthenticated &&
  request.facts.windowOccurrences == 1 &&
  nonzeroHex request.sourceIntervalSha256 &&
  nonzeroHex request.labelReceiptSha256 &&
  nonzeroHex request.outcomeEvidenceSha256 &&
  nonzeroHex request.usageEvidenceSha256 &&
  (!request.facts.trustworthySuccess || request.facts.taskSuccess)

def countsConsistent (facts : ImpactFacts) : Bool :=
  facts.exposures == facts.admits + facts.blocks + facts.faults &&
  facts.formalDecisions >= facts.exposures &&
  facts.formalFaults <= facts.formalDecisions &&
  facts.shadowDivergences <= facts.exposures &&
  facts.physicalCheckerCalls > 0 &&
  facts.physicalCheckerCalls <= facts.formalDecisions &&
  facts.checkerElapsedNs <= facts.wallElapsedNs

def usageConsistent (facts : ImpactFacts) : Bool :=
  facts.wallElapsedNs > 0 &&
  facts.meteredTokens == facts.inputTokens + facts.outputTokens +
    facts.cacheReadTokens + facts.cacheWriteTokens

def lifecycleValid (request : Request) : Bool :=
  match request.operation with
  | .promote => request.currentState == .shadowed
  | .demote | .quarantine => request.currentState == .promoted

def boundedCost (request : Request) : Bool :=
  request.facts.providerRequests <= request.policy.maxProviderRequests &&
  request.facts.meteredTokens <= request.policy.maxMeteredTokens &&
  request.facts.costMicrousd <= request.policy.maxCostMicrousd &&
  request.facts.wallElapsedNs <= request.policy.maxWallElapsedNs

def promotionPolicy (request : Request) : Bool :=
  request.facts.exposures >= request.policy.minExposures &&
  request.facts.taskSuccess && request.facts.trustworthySuccess &&
  !request.facts.driftDetected &&
  request.facts.formalFaults <= request.policy.maxFormalFaults &&
  request.facts.shadowDivergences <= request.policy.maxShadowDivergences &&
  request.facts.falseInterventions <= request.policy.maxFalseInterventions &&
  request.facts.regressions <= request.policy.maxRegressions &&
  boundedCost request

def demotionPolicy (request : Request) : Bool :=
  request.facts.driftDetected ||
  request.facts.regressions > request.policy.maxRegressions

def quarantinePolicy (request : Request) : Bool :=
  request.facts.formalFaults > request.policy.maxFormalFaults ||
  request.facts.shadowDivergences > request.policy.maxShadowDivergences ||
  request.facts.falseInterventions > request.policy.maxFalseInterventions

def policySatisfied (request : Request) : Bool :=
  match request.operation with
  | .promote => promotionPolicy request
  | .demote => demotionPolicy request
  | .quarantine => quarantinePolicy request

def SafeTransition (request : Request) : Bool :=
  bindingsValid request && evidenceValid request && countsConsistent request.facts &&
  usageConsistent request.facts && lifecycleValid request && policySatisfied request

theorem safeTransition_sound (request : Request)
    (admitted : SafeTransition request = true) :
    bindingsValid request = true ∧
    evidenceValid request = true ∧
    countsConsistent request.facts = true ∧
    usageConsistent request.facts = true ∧
    lifecycleValid request = true ∧
    policySatisfied request = true := by
  simp [SafeTransition] at admitted
  simpa only [and_assoc] using admitted

theorem unauthenticated_evidence_cannot_transition (request : Request)
    (missing : request.facts.evidenceAuthenticated = false) :
    SafeTransition request = false := by
  simp [SafeTransition, evidenceValid, missing]

theorem duplicate_window_cannot_transition (request : Request)
    (duplicate : (request.facts.windowOccurrences == 1) = false) :
    SafeTransition request = false := by
  simp [SafeTransition, evidenceValid, duplicate]

theorem unmetered_cache_cannot_transition (request : Request)
    (mismatch : (request.facts.meteredTokens ==
      request.facts.inputTokens + request.facts.outputTokens +
      request.facts.cacheReadTokens + request.facts.cacheWriteTokens) = false) :
    SafeTransition request = false := by
  simp [SafeTransition, usageConsistent, mismatch]

def operationName : Operation → String
  | .promote => "promote"
  | .demote => "demote"
  | .quarantine => "quarantine"

def operationOfString? : String → Option Operation
  | "promote" => some .promote
  | "demote" => some .demote
  | "quarantine" => some .quarantine
  | _ => none

def stateOfString? : String → Option RuleState
  | "shadowed" => some .shadowed
  | "promoted" => some .promoted
  | "quarantined" => some .quarantined
  | _ => none

def parseOperationField (cursor : Cursor) (name : String) :
    Except String (Operation × Cursor) := do
  let (raw, cursor) ← parseStringField cursor name
  match operationOfString? raw with
  | some operation => pure (operation, cursor)
  | none => throw "unsupported RuleImpact governance operation"

def parseStateField (cursor : Cursor) (name : String) :
    Except String (RuleState × Cursor) := do
  let (raw, cursor) ← parseStringField cursor name
  match stateOfString? raw with
  | some state => pure (state, cursor)
  | none => throw "unsupported project rule state"

def validateRequest (request : Request) : Except String Request := do
  if request.schemaVersion != requestSchema then throw "unsupported RuleImpact request schema"
  if request.expectedCheckerVersion != checkerVersion then throw "checker version mismatch"
  if !validLowerHex64 request.requestId || !validLowerHex64 request.kernelSha256 ||
      !validLowerHex64 request.candidateId || !validLowerHex64 request.projectSha256 ||
      !validLowerHex64 request.issuerSha256 || !validLowerHex64 request.bundleSha256 ||
      !validLowerHex64 request.sourceIntervalSha256 ||
      !validLowerHex64 request.labelReceiptSha256 ||
      !validLowerHex64 request.outcomeEvidenceSha256 ||
      !validLowerHex64 request.usageEvidenceSha256 then
    throw "RuleImpact identity must be 64 lowercase hex characters"
  if request.bundleRevision == 0 then throw "bundle revision must be positive"
  if request.facts.windowOccurrences > 4096 || request.facts.formalDecisions > 1048576 ||
      request.facts.exposures > 1048576 then throw "RuleImpact count exceeds protocol bound"
  pure request

def decodeCanonicalRequest (input : String) : Except String Request := do
  let cursor : Cursor := { remaining := input.toList }
  let cursor ← expectLiteral cursor "{\"schema_version\":"
  let (schemaVersion, cursor) ← parseString cursor
  let cursor ← expectLiteral cursor ","
  let (requestId, cursor) ← parseStringField cursor "request_id"
  let cursor ← expectLiteral cursor ","
  let (operation, cursor) ← parseOperationField cursor "operation"
  let cursor ← expectLiteral cursor ","
  let (expectedCheckerVersion, cursor) ← parseStringField cursor "expected_checker_version"
  let cursor ← expectLiteral cursor ","
  let (kernelSha256, cursor) ← parseStringField cursor "kernel_sha256"
  let cursor ← expectLiteral cursor ","
  let (candidateId, cursor) ← parseStringField cursor "candidate_id"
  let cursor ← expectLiteral cursor ","
  let (projectSha256, cursor) ← parseStringField cursor "project_sha256"
  let cursor ← expectLiteral cursor ","
  let (issuerSha256, cursor) ← parseStringField cursor "issuer_sha256"
  let cursor ← expectLiteral cursor ","
  let (bundleSha256, cursor) ← parseStringField cursor "bundle_sha256"
  let cursor ← expectLiteral cursor ","
  let (bundleRevision, cursor) ← parseNatField cursor "bundle_revision"
  let cursor ← expectLiteral cursor ","
  let (currentState, cursor) ← parseStateField cursor "current_state"
  let cursor ← expectLiteral cursor ","
  let (sourceIntervalSha256, cursor) ← parseStringField cursor "source_interval_sha256"
  let cursor ← expectLiteral cursor ","
  let (labelReceiptSha256, cursor) ← parseStringField cursor "label_receipt_sha256"
  let cursor ← expectLiteral cursor ","
  let (outcomeEvidenceSha256, cursor) ← parseStringField cursor "outcome_evidence_sha256"
  let cursor ← expectLiteral cursor ","
  let (usageEvidenceSha256, cursor) ← parseStringField cursor "usage_evidence_sha256"
  let cursor ← expectLiteral cursor ",\"facts\":{"
  let (completedRun, cursor) ← parseBoolField cursor "completed_run"
  let cursor ← expectLiteral cursor ","
  let (evidenceAuthenticated, cursor) ← parseBoolField cursor "evidence_authenticated"
  let cursor ← expectLiteral cursor ","
  let (windowOccurrences, cursor) ← parseNatField cursor "window_occurrences"
  let cursor ← expectLiteral cursor ","
  let (formalDecisions, cursor) ← parseNatField cursor "formal_decisions"
  let cursor ← expectLiteral cursor ","
  let (formalFaults, cursor) ← parseNatField cursor "formal_faults"
  let cursor ← expectLiteral cursor ","
  let (exposures, cursor) ← parseNatField cursor "exposures"
  let cursor ← expectLiteral cursor ","
  let (admits, cursor) ← parseNatField cursor "admits"
  let cursor ← expectLiteral cursor ","
  let (blocks, cursor) ← parseNatField cursor "blocks"
  let cursor ← expectLiteral cursor ","
  let (faults, cursor) ← parseNatField cursor "faults"
  let cursor ← expectLiteral cursor ","
  let (shadowDivergences, cursor) ← parseNatField cursor "shadow_divergences"
  let cursor ← expectLiteral cursor ","
  let (taskSuccess, cursor) ← parseBoolField cursor "task_success"
  let cursor ← expectLiteral cursor ","
  let (trustworthySuccess, cursor) ← parseBoolField cursor "trustworthy_success"
  let cursor ← expectLiteral cursor ","
  let (driftDetected, cursor) ← parseBoolField cursor "drift_detected"
  let cursor ← expectLiteral cursor ","
  let (falseInterventions, cursor) ← parseNatField cursor "false_interventions"
  let cursor ← expectLiteral cursor ","
  let (regressions, cursor) ← parseNatField cursor "regressions"
  let cursor ← expectLiteral cursor ","
  let (physicalCheckerCalls, cursor) ← parseNatField cursor "physical_checker_calls"
  let cursor ← expectLiteral cursor ","
  let (checkerElapsedNs, cursor) ← parseNatField cursor "checker_elapsed_ns"
  let cursor ← expectLiteral cursor ","
  let (providerRequests, cursor) ← parseNatField cursor "provider_requests"
  let cursor ← expectLiteral cursor ","
  let (inputTokens, cursor) ← parseNatField cursor "input_tokens"
  let cursor ← expectLiteral cursor ","
  let (outputTokens, cursor) ← parseNatField cursor "output_tokens"
  let cursor ← expectLiteral cursor ","
  let (cacheReadTokens, cursor) ← parseNatField cursor "cache_read_tokens"
  let cursor ← expectLiteral cursor ","
  let (cacheWriteTokens, cursor) ← parseNatField cursor "cache_write_tokens"
  let cursor ← expectLiteral cursor ","
  let (meteredTokens, cursor) ← parseNatField cursor "metered_tokens"
  let cursor ← expectLiteral cursor ","
  let (costMicrousd, cursor) ← parseNatField cursor "cost_microusd"
  let cursor ← expectLiteral cursor ","
  let (wallElapsedNs, cursor) ← parseNatField cursor "wall_elapsed_ns"
  let cursor ← expectLiteral cursor "},\"policy\":{"
  let (minExposures, cursor) ← parseNatField cursor "min_exposures"
  let cursor ← expectLiteral cursor ","
  let (maxFormalFaults, cursor) ← parseNatField cursor "max_formal_faults"
  let cursor ← expectLiteral cursor ","
  let (maxShadowDivergences, cursor) ← parseNatField cursor "max_shadow_divergences"
  let cursor ← expectLiteral cursor ","
  let (maxFalseInterventions, cursor) ← parseNatField cursor "max_false_interventions"
  let cursor ← expectLiteral cursor ","
  let (maxRegressions, cursor) ← parseNatField cursor "max_regressions"
  let cursor ← expectLiteral cursor ","
  let (maxProviderRequests, cursor) ← parseNatField cursor "max_provider_requests"
  let cursor ← expectLiteral cursor ","
  let (maxMeteredTokens, cursor) ← parseNatField cursor "max_metered_tokens"
  let cursor ← expectLiteral cursor ","
  let (maxCostMicrousd, cursor) ← parseNatField cursor "max_cost_microusd"
  let cursor ← expectLiteral cursor ","
  let (maxWallElapsedNs, cursor) ← parseNatField cursor "max_wall_elapsed_ns"
  let cursor ← expectLiteral cursor "}}"
  if !cursor.remaining.isEmpty then throw "trailing bytes after RuleImpact request"
  validateRequest {
    schemaVersion, requestId, operation, expectedCheckerVersion, kernelSha256,
    candidateId, projectSha256, issuerSha256, bundleSha256, bundleRevision, currentState,
    sourceIntervalSha256, labelReceiptSha256, outcomeEvidenceSha256,
    usageEvidenceSha256,
    facts := {
      completedRun := completedRun
      evidenceAuthenticated := evidenceAuthenticated
      windowOccurrences := windowOccurrences
      formalDecisions := formalDecisions
      formalFaults := formalFaults
      exposures := exposures
      admits := admits
      blocks := blocks
      faults := faults
      shadowDivergences := shadowDivergences
      taskSuccess := taskSuccess
      trustworthySuccess := trustworthySuccess
      driftDetected := driftDetected
      falseInterventions := falseInterventions
      regressions := regressions
      physicalCheckerCalls := physicalCheckerCalls
      checkerElapsedNs := checkerElapsedNs
      providerRequests := providerRequests
      inputTokens := inputTokens
      outputTokens := outputTokens
      cacheReadTokens := cacheReadTokens
      cacheWriteTokens := cacheWriteTokens
      meteredTokens := meteredTokens
      costMicrousd := costMicrousd
      wallElapsedNs := wallElapsedNs
    },
    policy := {
      minExposures := minExposures
      maxFormalFaults := maxFormalFaults
      maxShadowDivergences := maxShadowDivergences
      maxFalseInterventions := maxFalseInterventions
      maxRegressions := maxRegressions
      maxProviderRequests := maxProviderRequests
      maxMeteredTokens := maxMeteredTokens
      maxCostMicrousd := maxCostMicrousd
      maxWallElapsedNs := maxWallElapsedNs
    }
  }

def failureCodes (request : Request) : List String :=
  let failures := if bindingsValid request then [] else ["impact_binding_invalid"]
  let failures := if evidenceValid request then failures else failures ++ ["impact_evidence_invalid"]
  let failures := if countsConsistent request.facts then failures else failures ++ ["impact_counts_invalid"]
  let failures := if usageConsistent request.facts then failures else failures ++ ["impact_usage_invalid"]
  let failures := if lifecycleValid request then failures else failures ++ ["impact_lifecycle_invalid"]
  if policySatisfied request then failures else failures ++ ["impact_policy_not_satisfied"]

def verdictJson (request : Request) : String :=
  let admitted := SafeTransition request
  "{" ++
  "\"schema_version\":\"" ++ verdictSchema ++ "\"," ++
  "\"checker_version\":\"" ++ checkerVersion ++ "\"," ++
  "\"request_id\":\"" ++ request.requestId ++ "\"," ++
  "\"operation\":\"" ++ operationName request.operation ++ "\"," ++
  "\"kernel_sha256\":\"" ++ request.kernelSha256 ++ "\"," ++
  "\"candidate_id\":\"" ++ request.candidateId ++ "\"," ++
  "\"project_sha256\":\"" ++ request.projectSha256 ++ "\"," ++
  "\"issuer_sha256\":\"" ++ request.issuerSha256 ++ "\"," ++
  "\"bundle_sha256\":\"" ++ request.bundleSha256 ++ "\"," ++
  "\"bundle_revision\":" ++ toString request.bundleRevision ++ "," ++
  "\"source_interval_sha256\":\"" ++ request.sourceIntervalSha256 ++ "\"," ++
  "\"label_receipt_sha256\":\"" ++ request.labelReceiptSha256 ++ "\"," ++
  "\"outcome_evidence_sha256\":\"" ++ request.outcomeEvidenceSha256 ++ "\"," ++
  "\"usage_evidence_sha256\":\"" ++ request.usageEvidenceSha256 ++ "\"," ++
  "\"decision\":\"" ++ (if admitted then "admit" else "block") ++ "\"," ++
  "\"admitted\":" ++ boolJson admitted ++ "," ++
  "\"reason_codes\":" ++ reasonCodesJson (failureCodes request) ++ "," ++
  "\"checks\":{" ++
    "\"bindings_valid\":" ++ boolJson (bindingsValid request) ++ "," ++
    "\"evidence_valid\":" ++ boolJson (evidenceValid request) ++ "," ++
    "\"counts_consistent\":" ++ boolJson (countsConsistent request.facts) ++ "," ++
    "\"usage_consistent\":" ++ boolJson (usageConsistent request.facts) ++ "," ++
    "\"lifecycle_valid\":" ++ boolJson (lifecycleValid request) ++ "," ++
    "\"policy_satisfied\":" ++ boolJson (policySatisfied request) ++
  "}}"

end MetaCodesControl.RuleImpactGovernance
