import MetaCodesControl.FormalKernel
import MetaCodesControl.ProjectRule

namespace MetaCodesControl.ProjectHarness

open MetaCodesControl.FormalKernel
open MetaCodesControl.ProjectRule

def requestSchema : String := "metacodes-project-harness-request-v2"
def verdictSchema : String := "metacodes-project-harness-verdict-v2"
def batchRequestSchema : String := "metacodes-project-harness-batch-request-v2"
def batchVerdictSchema : String := "metacodes-project-harness-batch-verdict-v2"
def checkerVersion : String := "metacodes-project-harness-kernel-v2"
def maxBatchRequests : Nat := 1024
def zeroSha256 : String := "0000000000000000000000000000000000000000000000000000000000000000"

inductive SourceKind where
  | userCorrection
  | agentReflection
  | runtimeCounterexample
  deriving Repr, BEq, DecidableEq

inductive Operation where
  | promote
  | preDecision
  | postDecision
  deriving Repr, BEq, DecidableEq

structure PromotionFacts where
  sourceKind : SourceKind
  sourceReceiptBound : Bool
  proposer : String
  builder : String
  auditor : String
  replayEvaluator : String
  shadowEvaluator : String
  promoter : String
  replayChecker : String
  shadowChecker : String
  buildReceipt : String
  axiomPredecessor : String
  axiomReceipt : String
  replayPredecessor : String
  replayReceipt : String
  shadowPredecessor : String
  buildManifest : String
  ruleSpecSha256 : String
  sdkOlean : String
  buildCompleted : Bool
  axiomCompleted : Bool
  forbiddenDeclarationCount : Nat
  unexpectedAxiomCount : Nat
  replayCompleted : Bool
  replayPositiveCases : Nat
  replayNegativeCases : Nat
  replayFalsePositiveCount : Nat
  replayFalseNegativeCount : Nat
  shadowCompleted : Bool
  shadowObservedDecisions : Nat
  shadowDivergenceCount : Nat
  shadowSideEffectCount : Nat
  previousRevision : Nat
  previousBundleSha256 : String
  previousRuleCount : Nat
  bundleRuleCount : Nat
  candidateOccurrences : Nat
  deriving Repr, BEq

inductive Payload where
  | promotion : PromotionFacts → Payload
  | pre : PreSignal → Payload
  | post : PostSignal → Payload
  deriving Repr, BEq

structure Request where
  schemaVersion : String
  requestId : String
  operation : Operation
  expectedCheckerVersion : String
  kernelSha256 : String
  candidateId : String
  projectSha256 : String
  bundleSha256 : String
  bundleRevision : Nat
  ruleSpec : RuleSpec
  payload : Payload
  deriving Repr, BEq

def nonzeroHex (value : String) : Bool :=
  validLowerHex64 value && value != zeroSha256

def sourceValid (facts : PromotionFacts) : Bool :=
  match facts.sourceKind with
  | .userCorrection | .runtimeCounterexample => facts.sourceReceiptBound
  | .agentReflection => true

def actorsIndependent (facts : PromotionFacts) : Bool :=
  let actors := [facts.proposer, facts.builder, facts.auditor,
    facts.replayEvaluator, facts.shadowEvaluator, facts.promoter]
  actors.all validLowerHex64 &&
    actors.eraseDups.length == actors.length

def chainValid (facts : PromotionFacts) : Bool :=
  nonzeroHex facts.buildReceipt && nonzeroHex facts.axiomReceipt &&
  nonzeroHex facts.replayReceipt &&
  facts.axiomPredecessor == facts.buildReceipt &&
  facts.replayPredecessor == facts.axiomReceipt &&
  facts.shadowPredecessor == facts.replayReceipt

def buildValid (facts : PromotionFacts) : Bool :=
  facts.buildCompleted && facts.axiomCompleted &&
  facts.forbiddenDeclarationCount == 0 && facts.unexpectedAxiomCount == 0 &&
  nonzeroHex facts.buildManifest && nonzeroHex facts.ruleSpecSha256 &&
  nonzeroHex facts.sdkOlean

def replayValid (request : Request) (facts : PromotionFacts) : Bool :=
  facts.replayCompleted && facts.replayPositiveCases > 0 &&
  facts.replayNegativeCases > 0 && facts.replayFalsePositiveCount == 0 &&
  facts.replayFalseNegativeCount == 0 && facts.replayChecker == request.kernelSha256

def shadowValid (request : Request) (facts : PromotionFacts) : Bool :=
  facts.shadowCompleted && facts.shadowObservedDecisions > 0 &&
  facts.shadowDivergenceCount == 0 && facts.shadowSideEffectCount == 0 &&
  facts.shadowChecker == request.kernelSha256

def bundleTransitionValid (request : Request) (facts : PromotionFacts) : Bool :=
  request.bundleRevision == facts.previousRevision + 1 &&
  facts.bundleRuleCount == facts.previousRuleCount + 1 &&
  facts.candidateOccurrences == 1 &&
  (if facts.previousRevision == 0 then
    facts.previousBundleSha256 == zeroSha256
   else nonzeroHex facts.previousBundleSha256)

def requestBindingsValid (request : Request) : Bool :=
  request.schemaVersion == requestSchema &&
  request.expectedCheckerVersion == checkerVersion &&
  nonzeroHex request.kernelSha256 &&
  nonzeroHex request.requestId && nonzeroHex request.candidateId &&
  nonzeroHex request.projectSha256 && nonzeroHex request.bundleSha256 &&
  request.bundleRevision > 0

def promotionObligations (request : Request) (facts : PromotionFacts) : Bool :=
  sourceValid facts && (actorsIndependent facts && (chainValid facts &&
  (buildValid facts && (replayValid request facts && (shadowValid request facts &&
  bundleTransitionValid request facts)))))

def SafePromotion (request : Request) (facts : PromotionFacts) : Bool :=
  request.operation == .promote && (requestBindingsValid request &&
  (valid request.ruleSpec && promotionObligations request facts))

def decide (request : Request) : Bool :=
  match request.payload with
  | .promotion facts => SafePromotion request facts
  | .pre signal =>
      request.operation == .preDecision && requestBindingsValid request &&
        valid request.ruleSpec && preDecision request.ruleSpec signal
  | .post signal =>
      request.operation == .postDecision && requestBindingsValid request &&
        valid request.ruleSpec && postDecision request.ruleSpec signal

theorem safePromotion_sound (request : Request) (facts : PromotionFacts)
    (admitted : SafePromotion request facts = true) :
    promotionObligations request facts = true := by
  simp only [SafePromotion, Bool.and_eq_true] at admitted
  exact admitted.2.2.2

theorem correction_promotion_requires_receipt (request : Request)
    (facts : PromotionFacts) (kind : facts.sourceKind = .userCorrection)
    (admitted : SafePromotion request facts = true) :
    facts.sourceReceiptBound = true := by
  have obligations := safePromotion_sound request facts admitted
  simp only [promotionObligations, Bool.and_eq_true] at obligations
  have source := obligations.1
  simpa [sourceValid, kind] using source

theorem denied_all_predecision_blocks (request : Request) (signal : PreSignal)
    (payload : request.payload = .pre signal)
    (same : signal.tool = request.ruleSpec.targetTool)
    (scope : request.ruleSpec.targetScope = .all)
    (denied : request.ruleSpec.denyTarget = true) :
    decide request = false := by
  simp [decide, payload, preDecision, matchedDecision, same, scope, denied]

theorem denied_existing_file_predecision_blocks (request : Request)
    (signal : PreSignal) (payload : request.payload = .pre signal)
    (same : signal.tool = request.ruleSpec.targetTool)
    (scope : request.ruleSpec.targetScope = .existingFile)
    (state : signal.fileTargetState = .regularExisting)
    (denied : request.ruleSpec.denyTarget = true) :
    decide request = false := by
  simp [decide, payload, preDecision, matchedDecision, same, scope, state, denied]

/-- A batch is admitted exactly when every independently bound request is
admitted.  Batching changes process topology only; it cannot let one rule hide
another rule's block or malformed binding. -/
def decideBatch (requests : List Request) : Bool := requests.all decide

theorem decideBatch_sound (requests : List Request) :
    decideBatch requests = requests.all decide := by
  rfl

def sourceName : SourceKind → String
  | .userCorrection => "user_correction"
  | .agentReflection => "agent_reflection"
  | .runtimeCounterexample => "runtime_counterexample"

def operationName : Operation → String
  | .promote => "promote"
  | .preDecision => "pre_decision"
  | .postDecision => "post_decision"

def effectOfString? : String → Option EffectRequirement
  | "none" => some .none
  | "file_mutation_v1_reobserved" => some .fileMutationV1Reobserved
  | _ => none

def scopeOfString? : String → Option TargetScope
  | "all" => some .all
  | "existing_file" => some .existingFile
  | _ => none

def fileTargetStateOfString? : String → Option FileTargetState
  | "unobserved" => some .unobserved
  | "missing" => some .missing
  | "regular_existing" => some .regularExisting
  | "other_existing" => some .otherExisting
  | "unavailable" => some .unavailable
  | _ => none

def sourceOfString? : String → Option SourceKind
  | "user_correction" => some .userCorrection
  | "agent_reflection" => some .agentReflection
  | "runtime_counterexample" => some .runtimeCounterexample
  | _ => none

def operationOfString? : String → Option Operation
  | "promote" => some .promote
  | "pre_decision" => some .preDecision
  | "post_decision" => some .postDecision
  | _ => none

def parseEffectField (cursor : Cursor) (name : String) :
    Except String (EffectRequirement × Cursor) := do
  let (raw, cursor) ← parseStringField cursor name
  match effectOfString? raw with
  | some effect => pure (effect, cursor)
  | none => throw "unsupported effect requirement"

def parseScopeField (cursor : Cursor) (name : String) :
    Except String (TargetScope × Cursor) := do
  let (raw, cursor) ← parseStringField cursor name
  match scopeOfString? raw with
  | some scope => pure (scope, cursor)
  | none => throw "unsupported target scope"

def parseFileTargetStateField (cursor : Cursor) (name : String) :
    Except String (FileTargetState × Cursor) := do
  let (raw, cursor) ← parseStringField cursor name
  match fileTargetStateOfString? raw with
  | some state => pure (state, cursor)
  | none => throw "unsupported file target state"

def parseRuleSpec (cursor : Cursor) : Except String (RuleSpec × Cursor) := do
  let cursor ← expectLiteral cursor "{\"schema_version\":"
  let (schema, cursor) ← parseString cursor
  let cursor ← expectLiteral cursor ","
  let (targetTool, cursor) ← parseStringField cursor "target_tool"
  let cursor ← expectLiteral cursor ","
  let (targetScope, cursor) ← parseScopeField cursor "target_scope"
  let cursor ← expectLiteral cursor ","
  let (denyTarget, cursor) ← parseBoolField cursor "deny_target"
  let cursor ← expectLiteral cursor ","
  let (maxInputBytes, cursor) ← parseNatField cursor "max_input_bytes"
  let cursor ← expectLiteral cursor ","
  let (maxAgentDepth, cursor) ← parseNatField cursor "max_agent_depth"
  let cursor ← expectLiteral cursor ","
  let (authoritativeOnly, cursor) ← parseBoolField cursor "authoritative_only"
  let cursor ← expectLiteral cursor ","
  let (effectRequirement, cursor) ← parseEffectField cursor "effect_requirement"
  let cursor ← expectLiteral cursor "}"
  if schema != specSchema then throw "unsupported project rule spec"
  let spec : RuleSpec := {
    targetTool := targetTool
    targetScope := targetScope
    denyTarget := denyTarget
    maxInputBytes := maxInputBytes
    maxAgentDepth := maxAgentDepth
    authoritativeOnly := authoritativeOnly
    effectRequirement := effectRequirement
  }
  pure (spec, cursor)

def parsePreSignal (cursor : Cursor) : Except String (PreSignal × Cursor) := do
  let cursor ← expectLiteral cursor "{"
  let (tool, cursor) ← parseStringField cursor "tool"
  let cursor ← expectLiteral cursor ","
  let (inputBytes, cursor) ← parseNatField cursor "input_bytes"
  let cursor ← expectLiteral cursor ","
  let (agentDepth, cursor) ← parseNatField cursor "agent_depth"
  let cursor ← expectLiteral cursor ","
  let (authoritative, cursor) ← parseBoolField cursor "authoritative"
  let cursor ← expectLiteral cursor ","
  let (fileTargetState, cursor) ←
    parseFileTargetStateField cursor "file_target_state"
  let cursor ← expectLiteral cursor "}"
  let signal : PreSignal := {
    tool := tool
    inputBytes := inputBytes
    agentDepth := agentDepth
    authoritative := authoritative
    fileTargetState := fileTargetState
  }
  pure (signal, cursor)

def parsePostSignal (cursor : Cursor) : Except String (PostSignal × Cursor) := do
  let cursor ← expectLiteral cursor "{\"pre\":"
  let (pre, cursor) ← parsePreSignal cursor
  let cursor ← expectLiteral cursor ","
  let (succeeded, cursor) ← parseBoolField cursor "succeeded"
  let cursor ← expectLiteral cursor ","
  let (effectValid, cursor) ← parseBoolField cursor "effect_valid"
  let cursor ← expectLiteral cursor ","
  let (hasFileMutationV1, cursor) ← parseBoolField cursor "has_file_mutation_v1"
  let cursor ← expectLiteral cursor ","
  let (postReobserved, cursor) ← parseBoolField cursor "post_reobserved"
  let cursor ← expectLiteral cursor "}"
  let signal : PostSignal := {
    pre := pre
    succeeded := succeeded
    effectValid := effectValid
    hasFileMutationV1 := hasFileMutationV1
    postReobserved := postReobserved
  }
  pure (signal, cursor)

def parsePromotionFacts (cursor : Cursor) : Except String (PromotionFacts × Cursor) := do
  let cursor ← expectLiteral cursor "{"
  let (sourceRaw, cursor) ← parseStringField cursor "source_kind"
  let sourceKind ← match sourceOfString? sourceRaw with
    | some kind => pure kind
    | none => throw "unsupported source kind"
  let cursor ← expectLiteral cursor ","
  let (sourceReceiptBound, cursor) ← parseBoolField cursor "source_receipt_bound"
  let cursor ← expectLiteral cursor ","
  let (proposer, cursor) ← parseStringField cursor "proposer"
  let cursor ← expectLiteral cursor ","
  let (builder, cursor) ← parseStringField cursor "builder"
  let cursor ← expectLiteral cursor ","
  let (auditor, cursor) ← parseStringField cursor "auditor"
  let cursor ← expectLiteral cursor ","
  let (replayEvaluator, cursor) ← parseStringField cursor "replay_evaluator"
  let cursor ← expectLiteral cursor ","
  let (shadowEvaluator, cursor) ← parseStringField cursor "shadow_evaluator"
  let cursor ← expectLiteral cursor ","
  let (promoter, cursor) ← parseStringField cursor "promoter"
  let cursor ← expectLiteral cursor ","
  let (replayChecker, cursor) ← parseStringField cursor "replay_checker"
  let cursor ← expectLiteral cursor ","
  let (shadowChecker, cursor) ← parseStringField cursor "shadow_checker"
  let cursor ← expectLiteral cursor ","
  let (buildReceipt, cursor) ← parseStringField cursor "build_receipt"
  let cursor ← expectLiteral cursor ","
  let (axiomPredecessor, cursor) ← parseStringField cursor "axiom_predecessor"
  let cursor ← expectLiteral cursor ","
  let (axiomReceipt, cursor) ← parseStringField cursor "axiom_receipt"
  let cursor ← expectLiteral cursor ","
  let (replayPredecessor, cursor) ← parseStringField cursor "replay_predecessor"
  let cursor ← expectLiteral cursor ","
  let (replayReceipt, cursor) ← parseStringField cursor "replay_receipt"
  let cursor ← expectLiteral cursor ","
  let (shadowPredecessor, cursor) ← parseStringField cursor "shadow_predecessor"
  let cursor ← expectLiteral cursor ","
  let (buildManifest, cursor) ← parseStringField cursor "build_manifest"
  let cursor ← expectLiteral cursor ","
  let (ruleSpecSha256, cursor) ← parseStringField cursor "rule_spec_sha256"
  let cursor ← expectLiteral cursor ","
  let (sdkOlean, cursor) ← parseStringField cursor "sdk_olean"
  let cursor ← expectLiteral cursor ","
  let (buildCompleted, cursor) ← parseBoolField cursor "build_completed"
  let cursor ← expectLiteral cursor ","
  let (axiomCompleted, cursor) ← parseBoolField cursor "axiom_completed"
  let cursor ← expectLiteral cursor ","
  let (forbiddenDeclarationCount, cursor) ← parseNatField cursor "forbidden_declaration_count"
  let cursor ← expectLiteral cursor ","
  let (unexpectedAxiomCount, cursor) ← parseNatField cursor "unexpected_axiom_count"
  let cursor ← expectLiteral cursor ","
  let (replayCompleted, cursor) ← parseBoolField cursor "replay_completed"
  let cursor ← expectLiteral cursor ","
  let (replayPositiveCases, cursor) ← parseNatField cursor "replay_positive_cases"
  let cursor ← expectLiteral cursor ","
  let (replayNegativeCases, cursor) ← parseNatField cursor "replay_negative_cases"
  let cursor ← expectLiteral cursor ","
  let (replayFalsePositiveCount, cursor) ← parseNatField cursor "replay_false_positive_count"
  let cursor ← expectLiteral cursor ","
  let (replayFalseNegativeCount, cursor) ← parseNatField cursor "replay_false_negative_count"
  let cursor ← expectLiteral cursor ","
  let (shadowCompleted, cursor) ← parseBoolField cursor "shadow_completed"
  let cursor ← expectLiteral cursor ","
  let (shadowObservedDecisions, cursor) ← parseNatField cursor "shadow_observed_decisions"
  let cursor ← expectLiteral cursor ","
  let (shadowDivergenceCount, cursor) ← parseNatField cursor "shadow_divergence_count"
  let cursor ← expectLiteral cursor ","
  let (shadowSideEffectCount, cursor) ← parseNatField cursor "shadow_side_effect_count"
  let cursor ← expectLiteral cursor ","
  let (previousRevision, cursor) ← parseNatField cursor "previous_revision"
  let cursor ← expectLiteral cursor ","
  let (previousBundleSha256, cursor) ← parseStringField cursor "previous_bundle_sha256"
  let cursor ← expectLiteral cursor ","
  let (previousRuleCount, cursor) ← parseNatField cursor "previous_rule_count"
  let cursor ← expectLiteral cursor ","
  let (bundleRuleCount, cursor) ← parseNatField cursor "bundle_rule_count"
  let cursor ← expectLiteral cursor ","
  let (candidateOccurrences, cursor) ← parseNatField cursor "candidate_occurrences"
  let cursor ← expectLiteral cursor "}"
  let facts : PromotionFacts := {
    sourceKind := sourceKind
    sourceReceiptBound := sourceReceiptBound
    proposer := proposer
    builder := builder
    auditor := auditor
    replayEvaluator := replayEvaluator
    shadowEvaluator := shadowEvaluator
    promoter := promoter
    replayChecker := replayChecker
    shadowChecker := shadowChecker
    buildReceipt := buildReceipt
    axiomPredecessor := axiomPredecessor
    axiomReceipt := axiomReceipt
    replayPredecessor := replayPredecessor
    replayReceipt := replayReceipt
    shadowPredecessor := shadowPredecessor
    buildManifest := buildManifest
    ruleSpecSha256 := ruleSpecSha256
    sdkOlean := sdkOlean
    buildCompleted := buildCompleted
    axiomCompleted := axiomCompleted
    forbiddenDeclarationCount := forbiddenDeclarationCount
    unexpectedAxiomCount := unexpectedAxiomCount
    replayCompleted := replayCompleted
    replayPositiveCases := replayPositiveCases
    replayNegativeCases := replayNegativeCases
    replayFalsePositiveCount := replayFalsePositiveCount
    replayFalseNegativeCount := replayFalseNegativeCount
    shadowCompleted := shadowCompleted
    shadowObservedDecisions := shadowObservedDecisions
    shadowDivergenceCount := shadowDivergenceCount
    shadowSideEffectCount := shadowSideEffectCount
    previousRevision := previousRevision
    previousBundleSha256 := previousBundleSha256
    previousRuleCount := previousRuleCount
    bundleRuleCount := bundleRuleCount
    candidateOccurrences := candidateOccurrences
  }
  pure (facts, cursor)

def parseCanonicalRequest (cursor : Cursor) : Except String (Request × Cursor) := do
  let cursor ← expectLiteral cursor "{\"schema_version\":"
  let (schemaVersion, cursor) ← parseString cursor
  let cursor ← expectLiteral cursor ","
  let (requestId, cursor) ← parseStringField cursor "request_id"
  let cursor ← expectLiteral cursor ","
  let (operationRaw, cursor) ← parseStringField cursor "operation"
  let operation ← match operationOfString? operationRaw with
    | some value => pure value
    | none => throw "unsupported operation"
  let cursor ← expectLiteral cursor ","
  let (expectedCheckerVersion, cursor) ← parseStringField cursor "expected_checker_version"
  let cursor ← expectLiteral cursor ","
  let (kernelSha256, cursor) ← parseStringField cursor "kernel_sha256"
  let cursor ← expectLiteral cursor ","
  let (candidateId, cursor) ← parseStringField cursor "candidate_id"
  let cursor ← expectLiteral cursor ","
  let (projectSha256, cursor) ← parseStringField cursor "project_sha256"
  let cursor ← expectLiteral cursor ","
  let (bundleSha256, cursor) ← parseStringField cursor "bundle_sha256"
  let cursor ← expectLiteral cursor ","
  let (bundleRevision, cursor) ← parseNatField cursor "bundle_revision"
  let cursor ← expectLiteral cursor ",\"rule_spec\":"
  let (ruleSpec, cursor) ← parseRuleSpec cursor
  let cursor ← expectLiteral cursor ",\"payload\":{"
  let (payload, cursor) ← match operation with
    | .promote => do
        let cursor ← expectLiteral cursor "\"promotion\":"
        let (facts, cursor) ← parsePromotionFacts cursor
        let cursor ← expectLiteral cursor "}}"
        pure (Payload.promotion facts, cursor)
    | .preDecision => do
        let cursor ← expectLiteral cursor "\"pre\":"
        let (signal, cursor) ← parsePreSignal cursor
        let cursor ← expectLiteral cursor "}}"
        pure (Payload.pre signal, cursor)
    | .postDecision => do
        let cursor ← expectLiteral cursor "\"post\":"
        let (signal, cursor) ← parsePostSignal cursor
        let cursor ← expectLiteral cursor "}}"
        pure (Payload.post signal, cursor)
  pure ({
    schemaVersion := schemaVersion
    requestId := requestId
    operation := operation
    expectedCheckerVersion := expectedCheckerVersion
    kernelSha256 := kernelSha256
    candidateId := candidateId
    projectSha256 := projectSha256
    bundleSha256 := bundleSha256
    bundleRevision := bundleRevision
    ruleSpec := ruleSpec
    payload := payload
  }, cursor)

def decodeCanonicalRequest (input : String) : Except String Request := do
  let (request, cursor) ← parseCanonicalRequest { remaining := input.toList }
  if !cursor.remaining.isEmpty then throw "trailing bytes after project harness request"
  pure request

partial def parseBatchRequests (cursor : Cursor) (acc : List Request := []) :
    Except String (List Request × Cursor) := do
  if acc.length >= maxBatchRequests then throw "project harness batch exceeds rule bound"
  let (request, cursor) ← parseCanonicalRequest cursor
  let acc := request :: acc
  match cursor.remaining with
  | ',' :: rest => parseBatchRequests { remaining := rest } acc
  | ']' :: rest => pure (acc.reverse, { remaining := rest })
  | _ => throw "expected comma or end of project harness batch"

def decodeCanonicalBatchRequest (input : String) : Except String (List Request) := do
  let cursor : Cursor := { remaining := input.toList }
  let cursor ← expectLiteral cursor "{\"schema_version\":"
  let (schema, cursor) ← parseString cursor
  if schema != batchRequestSchema then throw "unsupported project harness batch schema"
  let cursor ← expectLiteral cursor ",\"requests\":["
  if cursor.remaining.take 1 == "]".toList then
    throw "project harness batch must contain at least one request"
  let (requests, cursor) ← parseBatchRequests cursor
  let cursor ← expectLiteral cursor "}"
  if !cursor.remaining.isEmpty then throw "trailing bytes after project harness batch request"
  pure requests

def lifecycleValid (request : Request) : Bool :=
  match request.payload with
  | .promotion facts => sourceValid facts && actorsIndependent facts &&
      chainValid facts && buildValid facts && replayValid request facts &&
      shadowValid request facts && bundleTransitionValid request facts
  | .pre _ | .post _ => true

def failureCodes (request : Request) : List String :=
  let failures := if requestBindingsValid request then [] else ["invalid_request_binding"]
  let failures := if valid request.ruleSpec then failures else failures ++ ["invalid_rule_spec"]
  match request.payload with
  | .promotion facts =>
      let failures := if sourceValid facts then failures else failures ++ ["source_evidence_missing"]
      let failures := if actorsIndependent facts then failures else failures ++ ["actors_not_independent"]
      let failures := if chainValid facts then failures else failures ++ ["receipt_chain_invalid"]
      let failures := if buildValid facts then failures else failures ++ ["build_or_axiom_invalid"]
      let failures := if replayValid request facts then failures else failures ++ ["replay_invalid"]
      let failures := if shadowValid request facts then failures else failures ++ ["shadow_invalid"]
      if bundleTransitionValid request facts then failures else failures ++ ["bundle_transition_invalid"]
  | .pre signal =>
      if preDecision request.ruleSpec signal then failures else failures ++ ["rule_precondition_blocked"]
  | .post signal =>
      if postDecision request.ruleSpec signal then failures else failures ++ ["rule_postcondition_blocked"]

def verdictJson (request : Request) : String :=
  let admitted := decide request
  "{" ++
  "\"schema_version\":\"" ++ verdictSchema ++ "\"," ++
  "\"checker_version\":\"" ++ checkerVersion ++ "\"," ++
  "\"request_id\":\"" ++ request.requestId ++ "\"," ++
  "\"operation\":\"" ++ operationName request.operation ++ "\"," ++
  "\"kernel_sha256\":\"" ++ request.kernelSha256 ++ "\"," ++
  "\"candidate_id\":\"" ++ request.candidateId ++ "\"," ++
  "\"project_sha256\":\"" ++ request.projectSha256 ++ "\"," ++
  "\"bundle_sha256\":\"" ++ request.bundleSha256 ++ "\"," ++
  "\"bundle_revision\":" ++ toString request.bundleRevision ++ "," ++
  "\"decision\":\"" ++ (if admitted then "admit" else "block") ++ "\"," ++
  "\"admitted\":" ++ FormalKernel.boolJson admitted ++ "," ++
  "\"reason_codes\":" ++ reasonCodesJson (failureCodes request) ++ "," ++
  "\"checks\":{" ++
    "\"request_valid\":" ++ FormalKernel.boolJson (requestBindingsValid request) ++ "," ++
    "\"rule_valid\":" ++ FormalKernel.boolJson (valid request.ruleSpec) ++ "," ++
    "\"lifecycle_valid\":" ++ FormalKernel.boolJson (lifecycleValid request) ++ "," ++
    "\"decision_valid\":true}}"

def batchVerdictJson (requests : List Request) : String :=
  "{" ++
  "\"schema_version\":\"" ++ batchVerdictSchema ++ "\"," ++
  "\"checker_version\":\"" ++ checkerVersion ++ "\"," ++
  "\"verdicts\":[" ++ String.intercalate "," (requests.map verdictJson) ++ "]}"

end MetaCodesControl.ProjectHarness
