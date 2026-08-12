import MetaCodesControl.RuleImpactGovernance

namespace MetaCodesControl.RuleImpactAggregateGovernance

open MetaCodesControl.FormalKernel
open MetaCodesControl.RuleImpactGovernance

set_option maxRecDepth 8192

def requestSchema : String := "metacodes-rule-impact-aggregate-governance-request-v1"
def verdictSchema : String := "metacodes-rule-impact-aggregate-governance-verdict-v1"
def maxMembers : Nat := 64

structure Window where
  projectSha256 : String
  issuerSha256 : String
  candidateId : String
  bundleSha256 : String
  bundleRevision : Nat
  sessionId : String
  runId : String
  firstSequence : Nat
  lastSequence : Nat
  sourceIntervalSha256 : String
  labelReceiptSha256 : String
  outcomeEvidenceSha256 : String
  usageEvidenceSha256 : String
  facts : ImpactFacts
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
  policyEpoch : Nat
  expectedPolicyEpoch : Nat
  aggregateReceiptSha256 : String
  membersSha256 : String
  sourceIntervalsSha256 : String
  outcomeEvidenceSha256 : String
  usageEvidenceSha256 : String
  facts : ImpactFacts
  members : List Window
  policy : Policy
  deriving Repr, BEq

def validSessionId (value : String) : Bool :=
  value.length == 24 && value.toList.all fun char =>
    ('0' ≤ char && char ≤ '9') || ('a' ≤ char && char ≤ 'f')

def bindingsValid (request : Request) : Bool :=
  request.schemaVersion == requestSchema &&
  request.expectedCheckerVersion == RuleImpactGovernance.checkerVersion &&
  nonzeroHex request.requestId && nonzeroHex request.kernelSha256 &&
  nonzeroHex request.candidateId && nonzeroHex request.projectSha256 &&
  nonzeroHex request.issuerSha256 && nonzeroHex request.bundleSha256 &&
  request.bundleRevision > 0 && request.policyEpoch > 0 &&
  request.expectedPolicyEpoch > 0

def memberIdentityValid (request : Request) (window : Window) : Bool :=
  window.projectSha256 == request.projectSha256 &&
  window.issuerSha256 == request.issuerSha256 &&
  window.candidateId == request.candidateId &&
  window.bundleSha256 == request.bundleSha256 &&
  window.bundleRevision == request.bundleRevision &&
  validSessionId window.sessionId && validSessionId window.runId &&
  window.firstSequence <= window.lastSequence &&
  nonzeroHex window.sourceIntervalSha256 &&
  nonzeroHex window.labelReceiptSha256 &&
  nonzeroHex window.outcomeEvidenceSha256 &&
  nonzeroHex window.usageEvidenceSha256

def memberFactsValid (facts : ImpactFacts) : Bool :=
  facts.completedRun && facts.evidenceAuthenticated &&
  facts.windowOccurrences == 1 &&
  (!facts.trustworthySuccess || facts.taskSuccess) &&
  countsConsistent facts && usageConsistent facts

def membersIndividuallyValid (request : Request) : Bool :=
  !request.members.isEmpty && request.members.length <= maxMembers &&
  request.members.all fun window =>
    memberIdentityValid request window && memberFactsValid window.facts

def uniqueReceipts : List Window → Bool
  | [] => true
  | head :: tail =>
      tail.all (fun item => item.labelReceiptSha256 != head.labelReceiptSha256) &&
      uniqueReceipts tail

def uniqueIntervals : List Window → Bool
  | [] => true
  | head :: tail =>
      tail.all (fun item => item.sourceIntervalSha256 != head.sourceIntervalSha256) &&
      uniqueIntervals tail

def windowsDisjoint (left right : Window) : Bool :=
  left.sessionId != right.sessionId ||
  left.lastSequence < right.firstSequence ||
  right.lastSequence < left.firstSequence

def nonoverlappingWindows : List Window → Bool
  | [] => true
  | head :: tail => tail.all (windowsDisjoint head) && nonoverlappingWindows tail

def sumFacts (windows : List Window) : ImpactFacts := {
  completedRun := windows.all fun window => window.facts.completedRun
  evidenceAuthenticated := windows.all fun window => window.facts.evidenceAuthenticated
  windowOccurrences := windows.length
  formalDecisions := windows.foldl (fun total window => total + window.facts.formalDecisions) 0
  formalFaults := windows.foldl (fun total window => total + window.facts.formalFaults) 0
  exposures := windows.foldl (fun total window => total + window.facts.exposures) 0
  admits := windows.foldl (fun total window => total + window.facts.admits) 0
  blocks := windows.foldl (fun total window => total + window.facts.blocks) 0
  faults := windows.foldl (fun total window => total + window.facts.faults) 0
  shadowDivergences := windows.foldl (fun total window => total + window.facts.shadowDivergences) 0
  taskSuccess := windows.all fun window => window.facts.taskSuccess
  trustworthySuccess := windows.all fun window => window.facts.trustworthySuccess
  driftDetected := windows.any fun window => window.facts.driftDetected
  falseInterventions := windows.foldl (fun total window => total + window.facts.falseInterventions) 0
  regressions := windows.foldl (fun total window => total + window.facts.regressions) 0
  physicalCheckerCalls := windows.foldl (fun total window => total + window.facts.physicalCheckerCalls) 0
  checkerElapsedNs := windows.foldl (fun total window => total + window.facts.checkerElapsedNs) 0
  providerRequests := windows.foldl (fun total window => total + window.facts.providerRequests) 0
  inputTokens := windows.foldl (fun total window => total + window.facts.inputTokens) 0
  outputTokens := windows.foldl (fun total window => total + window.facts.outputTokens) 0
  cacheReadTokens := windows.foldl (fun total window => total + window.facts.cacheReadTokens) 0
  cacheWriteTokens := windows.foldl (fun total window => total + window.facts.cacheWriteTokens) 0
  meteredTokens := windows.foldl (fun total window => total + window.facts.meteredTokens) 0
  costMicrousd := windows.foldl (fun total window => total + window.facts.costMicrousd) 0
  wallElapsedNs := windows.foldl (fun total window => total + window.facts.wallElapsedNs) 0
}

def aggregateExact (request : Request) : Bool := request.facts == sumFacts request.members

def evidenceValid (request : Request) : Bool :=
  request.policyEpoch == request.expectedPolicyEpoch &&
  nonzeroHex request.aggregateReceiptSha256 &&
  nonzeroHex request.membersSha256 && nonzeroHex request.sourceIntervalsSha256 &&
  nonzeroHex request.outcomeEvidenceSha256 && nonzeroHex request.usageEvidenceSha256 &&
  membersIndividuallyValid request && uniqueReceipts request.members &&
  uniqueIntervals request.members && nonoverlappingWindows request.members &&
  aggregateExact request

def lifecycleValid (request : Request) : Bool :=
  match request.operation with
  | .promote => request.currentState == .shadowed
  | .demote | .quarantine => request.currentState == .promoted

def boundedCost (request : Request) : Bool :=
  request.facts.providerRequests <= request.policy.maxProviderRequests &&
  request.facts.meteredTokens <= request.policy.maxMeteredTokens &&
  request.facts.costMicrousd <= request.policy.maxCostMicrousd &&
  request.facts.wallElapsedNs <= request.policy.maxWallElapsedNs

def policySatisfied (request : Request) : Bool :=
  match request.operation with
  | .promote =>
      request.facts.exposures >= request.policy.minExposures &&
      promotionOutcomeValid request.facts &&
      !request.facts.driftDetected &&
      request.facts.formalFaults <= request.policy.maxFormalFaults &&
      request.facts.shadowDivergences <= request.policy.maxShadowDivergences &&
      request.facts.falseInterventions <= request.policy.maxFalseInterventions &&
      request.facts.regressions <= request.policy.maxRegressions && boundedCost request
  | .demote => request.facts.driftDetected ||
      request.facts.regressions > request.policy.maxRegressions
  | .quarantine =>
      request.facts.formalFaults > request.policy.maxFormalFaults ||
      request.facts.shadowDivergences > request.policy.maxShadowDivergences ||
      request.facts.falseInterventions > request.policy.maxFalseInterventions

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

theorem admitted_preserves_member_obligations (request : Request)
    (admitted : SafeTransition request = true) :
    aggregateExact request = true ∧
    uniqueReceipts request.members = true ∧
    uniqueIntervals request.members = true ∧
    nonoverlappingWindows request.members = true := by
  have evidence := (safeTransition_sound request admitted).2.1
  rw [evidenceValid] at evidence
  simp only [Bool.and_eq_true] at evidence
  obtain ⟨evidence, exact⟩ := evidence
  obtain ⟨evidence, windowsDisjoint⟩ := evidence
  obtain ⟨evidence, intervalsUnique⟩ := evidence
  obtain ⟨_, receiptsUnique⟩ := evidence
  exact ⟨exact, receiptsUnique, intervalsUnique, windowsDisjoint⟩

theorem stale_policy_cannot_transition (request : Request)
    (stale : (request.policyEpoch == request.expectedPolicyEpoch) = false) :
    SafeTransition request = false := by
  simp [SafeTransition, evidenceValid, stale]

theorem duplicate_receipt_cannot_transition (request : Request)
    (duplicate : uniqueReceipts request.members = false) :
    SafeTransition request = false := by
  simp [SafeTransition, evidenceValid, duplicate]

theorem overlap_cannot_transition (request : Request)
    (overlap : nonoverlappingWindows request.members = false) :
    SafeTransition request = false := by
  simp [SafeTransition, evidenceValid, overlap]

theorem inexact_sum_cannot_transition (request : Request)
    (inexact : aggregateExact request = false) :
    SafeTransition request = false := by
  simp [SafeTransition, evidenceValid, inexact]

def parseFacts (cursor : Cursor) : Except String (ImpactFacts × Cursor) := do
  let cursor ← expectLiteral cursor "{"
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
  let cursor ← expectLiteral cursor "}"
  pure (({
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
  } : ImpactFacts), cursor)

def parsePolicy (cursor : Cursor) : Except String (Policy × Cursor) := do
  let cursor ← expectLiteral cursor "{"
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
  let cursor ← expectLiteral cursor "}"
  pure (({
    minExposures := minExposures
    maxFormalFaults := maxFormalFaults
    maxShadowDivergences := maxShadowDivergences
    maxFalseInterventions := maxFalseInterventions
    maxRegressions := maxRegressions
    maxProviderRequests := maxProviderRequests
    maxMeteredTokens := maxMeteredTokens
    maxCostMicrousd := maxCostMicrousd
    maxWallElapsedNs := maxWallElapsedNs
  } : Policy), cursor)

def parseWindow (cursor : Cursor) : Except String (Window × Cursor) := do
  let cursor ← expectLiteral cursor "{"
  let (projectSha256, cursor) ← parseStringField cursor "project_sha256"
  let cursor ← expectLiteral cursor ","
  let (issuerSha256, cursor) ← parseStringField cursor "issuer_sha256"
  let cursor ← expectLiteral cursor ","
  let (candidateId, cursor) ← parseStringField cursor "candidate_id"
  let cursor ← expectLiteral cursor ","
  let (bundleSha256, cursor) ← parseStringField cursor "bundle_sha256"
  let cursor ← expectLiteral cursor ","
  let (bundleRevision, cursor) ← parseNatField cursor "bundle_revision"
  let cursor ← expectLiteral cursor ","
  let (sessionId, cursor) ← parseStringField cursor "session_id"
  let cursor ← expectLiteral cursor ","
  let (runId, cursor) ← parseStringField cursor "run_id"
  let cursor ← expectLiteral cursor ","
  let (firstSequence, cursor) ← parseNatField cursor "first_sequence"
  let cursor ← expectLiteral cursor ","
  let (lastSequence, cursor) ← parseNatField cursor "last_sequence"
  let cursor ← expectLiteral cursor ","
  let (sourceIntervalSha256, cursor) ← parseStringField cursor "source_interval_sha256"
  let cursor ← expectLiteral cursor ","
  let (labelReceiptSha256, cursor) ← parseStringField cursor "label_receipt_sha256"
  let cursor ← expectLiteral cursor ","
  let (outcomeEvidenceSha256, cursor) ← parseStringField cursor "outcome_evidence_sha256"
  let cursor ← expectLiteral cursor ","
  let (usageEvidenceSha256, cursor) ← parseStringField cursor "usage_evidence_sha256"
  let cursor ← expectLiteral cursor ",\"facts\":"
  let (facts, cursor) ← parseFacts cursor
  let cursor ← expectLiteral cursor "}"
  pure (({
    projectSha256 := projectSha256
    issuerSha256 := issuerSha256
    candidateId := candidateId
    bundleSha256 := bundleSha256
    bundleRevision := bundleRevision
    sessionId := sessionId
    runId := runId
    firstSequence := firstSequence
    lastSequence := lastSequence
    sourceIntervalSha256 := sourceIntervalSha256
    labelReceiptSha256 := labelReceiptSha256
    outcomeEvidenceSha256 := outcomeEvidenceSha256
    usageEvidenceSha256 := usageEvidenceSha256
    facts := facts
  } : Window), cursor)

partial def parseWindows (cursor : Cursor) (acc : List Window := []) :
    Except String (List Window × Cursor) := do
  if acc.length >= maxMembers then throw "RuleImpact aggregate exceeds member bound"
  let (window, cursor) ← parseWindow cursor
  let acc := window :: acc
  match cursor.remaining with
  | ',' :: rest => parseWindows { remaining := rest } acc
  | ']' :: rest => pure (acc.reverse, { remaining := rest })
  | _ => throw "expected comma or end of RuleImpact aggregate members"

def validateRequest (request : Request) : Except String Request := do
  if request.schemaVersion != requestSchema then throw "unsupported aggregate request schema"
  if request.expectedCheckerVersion != RuleImpactGovernance.checkerVersion then
    throw "checker version mismatch"
  let ids := [request.requestId, request.kernelSha256, request.candidateId,
    request.projectSha256, request.issuerSha256, request.bundleSha256,
    request.aggregateReceiptSha256, request.membersSha256,
    request.sourceIntervalsSha256, request.outcomeEvidenceSha256,
    request.usageEvidenceSha256]
  if !(ids.all validLowerHex64) then
    throw "RuleImpact aggregate identity must be 64 lowercase hex characters"
  if request.bundleRevision == 0 || request.policyEpoch == 0 ||
      request.expectedPolicyEpoch == 0 then throw "aggregate revisions must be positive"
  if request.members.isEmpty || request.members.length > maxMembers then
    throw "RuleImpact aggregate member count out of range"
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
  let (policyEpoch, cursor) ← parseNatField cursor "policy_epoch"
  let cursor ← expectLiteral cursor ","
  let (expectedPolicyEpoch, cursor) ← parseNatField cursor "expected_policy_epoch"
  let cursor ← expectLiteral cursor ","
  let (aggregateReceiptSha256, cursor) ← parseStringField cursor "aggregate_receipt_sha256"
  let cursor ← expectLiteral cursor ","
  let (membersSha256, cursor) ← parseStringField cursor "members_sha256"
  let cursor ← expectLiteral cursor ","
  let (sourceIntervalsSha256, cursor) ← parseStringField cursor "source_intervals_sha256"
  let cursor ← expectLiteral cursor ","
  let (outcomeEvidenceSha256, cursor) ← parseStringField cursor "outcome_evidence_sha256"
  let cursor ← expectLiteral cursor ","
  let (usageEvidenceSha256, cursor) ← parseStringField cursor "usage_evidence_sha256"
  let cursor ← expectLiteral cursor ",\"facts\":"
  let (facts, cursor) ← parseFacts cursor
  let cursor ← expectLiteral cursor ",\"members\":["
  if cursor.remaining.take 1 == "]".toList then
    throw "RuleImpact aggregate must contain at least one member"
  let (members, cursor) ← parseWindows cursor
  let cursor ← expectLiteral cursor ",\"policy\":"
  let (policy, cursor) ← parsePolicy cursor
  let cursor ← expectLiteral cursor "}"
  if !cursor.remaining.isEmpty then throw "trailing bytes after RuleImpact aggregate request"
  validateRequest {
    schemaVersion := schemaVersion
    requestId := requestId
    operation := operation
    expectedCheckerVersion := expectedCheckerVersion
    kernelSha256 := kernelSha256
    candidateId := candidateId
    projectSha256 := projectSha256
    issuerSha256 := issuerSha256
    bundleSha256 := bundleSha256
    bundleRevision := bundleRevision
    currentState := currentState
    policyEpoch := policyEpoch
    expectedPolicyEpoch := expectedPolicyEpoch
    aggregateReceiptSha256 := aggregateReceiptSha256
    membersSha256 := membersSha256
    sourceIntervalsSha256 := sourceIntervalsSha256
    outcomeEvidenceSha256 := outcomeEvidenceSha256
    usageEvidenceSha256 := usageEvidenceSha256
    facts := facts
    members := members
    policy := policy
  }

def failureCodes (request : Request) : List String :=
  let failures := if bindingsValid request then [] else ["aggregate_binding_invalid"]
  let failures := if membersIndividuallyValid request then failures
    else failures ++ ["aggregate_member_invalid"]
  let failures := if uniqueReceipts request.members && uniqueIntervals request.members then failures
    else failures ++ ["aggregate_duplicate_member"]
  let failures := if nonoverlappingWindows request.members then failures
    else failures ++ ["aggregate_window_overlap"]
  let failures := if aggregateExact request then failures else failures ++ ["aggregate_sum_mismatch"]
  let failures := if evidenceValid request then failures else failures ++ ["aggregate_evidence_invalid"]
  let failures := if countsConsistent request.facts then failures else failures ++ ["impact_counts_invalid"]
  let failures := if usageConsistent request.facts then failures else failures ++ ["impact_usage_invalid"]
  let failures := if lifecycleValid request then failures else failures ++ ["impact_lifecycle_invalid"]
  if policySatisfied request then failures else failures ++ ["impact_policy_not_satisfied"]

def verdictJson (request : Request) : String :=
  let admitted := SafeTransition request
  "{" ++
  "\"schema_version\":\"" ++ verdictSchema ++ "\"," ++
  "\"checker_version\":\"" ++ RuleImpactGovernance.checkerVersion ++ "\"," ++
  "\"request_id\":\"" ++ request.requestId ++ "\"," ++
  "\"operation\":\"" ++ operationName request.operation ++ "\"," ++
  "\"kernel_sha256\":\"" ++ request.kernelSha256 ++ "\"," ++
  "\"candidate_id\":\"" ++ request.candidateId ++ "\"," ++
  "\"project_sha256\":\"" ++ request.projectSha256 ++ "\"," ++
  "\"issuer_sha256\":\"" ++ request.issuerSha256 ++ "\"," ++
  "\"bundle_sha256\":\"" ++ request.bundleSha256 ++ "\"," ++
  "\"bundle_revision\":" ++ toString request.bundleRevision ++ "," ++
  "\"policy_epoch\":" ++ toString request.policyEpoch ++ "," ++
  "\"aggregate_receipt_sha256\":\"" ++ request.aggregateReceiptSha256 ++ "\"," ++
  "\"members_sha256\":\"" ++ request.membersSha256 ++ "\"," ++
  "\"source_intervals_sha256\":\"" ++ request.sourceIntervalsSha256 ++ "\"," ++
  "\"outcome_evidence_sha256\":\"" ++ request.outcomeEvidenceSha256 ++ "\"," ++
  "\"usage_evidence_sha256\":\"" ++ request.usageEvidenceSha256 ++ "\"," ++
  "\"decision\":\"" ++ (if admitted then "admit" else "block") ++ "\"," ++
  "\"admitted\":" ++ boolJson admitted ++ "," ++
  "\"reason_codes\":" ++ reasonCodesJson (failureCodes request) ++ "," ++
  "\"checks\":{" ++
    "\"bindings_valid\":" ++ boolJson (bindingsValid request) ++ "," ++
    "\"evidence_valid\":" ++ boolJson (evidenceValid request) ++ "," ++
    "\"members_valid\":" ++ boolJson (membersIndividuallyValid request &&
      uniqueReceipts request.members && uniqueIntervals request.members &&
      nonoverlappingWindows request.members) ++ "," ++
    "\"aggregate_exact\":" ++ boolJson (aggregateExact request) ++ "," ++
    "\"counts_consistent\":" ++ boolJson (countsConsistent request.facts) ++ "," ++
    "\"usage_consistent\":" ++ boolJson (usageConsistent request.facts) ++ "," ++
    "\"lifecycle_valid\":" ++ boolJson (lifecycleValid request) ++ "," ++
    "\"policy_satisfied\":" ++ boolJson (policySatisfied request) ++
  "}}"

end MetaCodesControl.RuleImpactAggregateGovernance
