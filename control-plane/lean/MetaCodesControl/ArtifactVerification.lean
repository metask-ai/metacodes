import MetaCodesControl.FormalKernel

namespace MetaCodesControl.ArtifactVerification

open MetaCodesControl.FormalKernel

def requestSchema : String := "metacodes-artifact-verification-request-v1"

def zeroHash : String :=
  "0000000000000000000000000000000000000000000000000000000000000000"

inductive Phase where
  | candidate
  | verificationRequested
  | verified
  | defectFound
  | repairAuthorized
  | repaired
  | failed
  deriving Repr, BEq, DecidableEq

def Phase.decode : String → Option Phase
  | "candidate" => some .candidate
  | "verification_requested" => some .verificationRequested
  | "verified" => some .verified
  | "defect_found" => some .defectFound
  | "repair_authorized" => some .repairAuthorized
  | "repaired" => some .repaired
  | "failed" => some .failed
  | _ => none

def Phase.encode : Phase → String
  | .candidate => "candidate"
  | .verificationRequested => "verification_requested"
  | .verified => "verified"
  | .defectFound => "defect_found"
  | .repairAuthorized => "repair_authorized"
  | .repaired => "repaired"
  | .failed => "failed"

inductive EventKind where
  | requestVerification
  | markVerified
  | reportDefect
  | authorizeRepair
  | recordRepair
  | abandon
  deriving Repr, BEq, DecidableEq

def EventKind.decode : String → Option EventKind
  | "request_verification" => some .requestVerification
  | "mark_verified" => some .markVerified
  | "report_defect" => some .reportDefect
  | "authorize_repair" => some .authorizeRepair
  | "record_repair" => some .recordRepair
  | "abandon" => some .abandon
  | _ => none

structure State where
  phase : Phase
  task_sha256 : String
  actor_run_sha256 : String
  artifact_sha256 : String
  artifact_revision : String
  verifier_sha256 : String
  policy_sha256 : String
  budget_authority_sha256 : String
  active_provider_authorization_sha256 : String
  transition_revision : Nat
  repair_attempts : Nat
  max_repair_attempts : Nat
  semantic_verdict_sha256 : String
  defect_sha256 : String
  repair_proposal_sha256 : String
  deriving Repr, BEq

structure Proposal where
  event : EventKind
  expected_phase : Phase
  expected_next_phase : Phase
  expected_snapshot_revision : String
  next_snapshot_revision : String
  provider_authorization_sha256 : String
  semantic_verdict_sha256 : String
  defect_sha256 : String
  repair_proposal_sha256 : String
  next_artifact_sha256 : String
  next_artifact_revision : String
  deriving Repr, BEq

structure Request where
  schema_version : String
  request_id : String
  operation : String
  proposal_sha256 : String
  snapshot_sha256 : String
  snapshot_revision : String
  expected_checker_version : String
  state : State
  proposal : Proposal
  deriving Repr

def presentHash (value : String) : Bool :=
  validLowerHex64 value && value != zeroHash

def absentHash (value : String) : Bool := value == zeroHash

def identityComplete (state : State) : Bool :=
  presentHash state.task_sha256 &&
  presentHash state.actor_run_sha256 &&
  presentHash state.artifact_sha256 &&
  presentHash state.artifact_revision &&
  presentHash state.verifier_sha256 &&
  presentHash state.policy_sha256 &&
  presentHash state.budget_authority_sha256 &&
  state.max_repair_attempts > 0 &&
  state.max_repair_attempts <= 16 &&
  state.repair_attempts <= state.max_repair_attempts

def stateWellFormed (state : State) : Bool :=
  identityComplete state &&
  match state.phase with
  | .candidate =>
      state.transition_revision == 0 && state.repair_attempts == 0 &&
      absentHash state.active_provider_authorization_sha256 &&
      absentHash state.semantic_verdict_sha256 &&
      absentHash state.defect_sha256 && absentHash state.repair_proposal_sha256
  | .verificationRequested =>
      state.transition_revision > 0 &&
      presentHash state.active_provider_authorization_sha256 &&
      absentHash state.semantic_verdict_sha256 &&
      absentHash state.defect_sha256 && absentHash state.repair_proposal_sha256
  | .verified =>
      state.transition_revision > 0 &&
      absentHash state.active_provider_authorization_sha256 &&
      presentHash state.semantic_verdict_sha256 &&
      absentHash state.defect_sha256 && absentHash state.repair_proposal_sha256
  | .defectFound | .failed =>
      state.transition_revision > 0 &&
      absentHash state.active_provider_authorization_sha256 &&
      presentHash state.semantic_verdict_sha256 &&
      presentHash state.defect_sha256 && absentHash state.repair_proposal_sha256
  | .repairAuthorized =>
      state.transition_revision > 0 &&
      presentHash state.active_provider_authorization_sha256 &&
      presentHash state.semantic_verdict_sha256 &&
      presentHash state.defect_sha256 && presentHash state.repair_proposal_sha256
  | .repaired =>
      state.transition_revision > 0 && state.repair_attempts > 0 &&
      absentHash state.active_provider_authorization_sha256 &&
      absentHash state.semantic_verdict_sha256 &&
      absentHash state.defect_sha256 && absentHash state.repair_proposal_sha256

def requestBindingsValid (request : Request) : Bool :=
  request.schema_version == requestSchema &&
  request.operation == "artifact_transition" &&
  request.expected_checker_version == checkerVersion &&
  presentHash request.request_id &&
  presentHash request.proposal_sha256 &&
  presentHash request.snapshot_sha256 &&
  presentHash request.snapshot_revision

def proposalBound (request : Request) : Bool :=
  request.proposal.expected_phase == request.state.phase &&
  request.proposal.expected_snapshot_revision == request.snapshot_revision &&
  presentHash request.proposal.next_snapshot_revision &&
  request.proposal.next_snapshot_revision != request.snapshot_revision

def noProviderEvidence (proposal : Proposal) : Bool :=
  absentHash proposal.provider_authorization_sha256

def noSemanticEvidence (proposal : Proposal) : Bool :=
  absentHash proposal.semantic_verdict_sha256 &&
  absentHash proposal.defect_sha256

def noRepairProposal (proposal : Proposal) : Bool :=
  absentHash proposal.repair_proposal_sha256

def noArtifactReplacement (proposal : Proposal) : Bool :=
  absentHash proposal.next_artifact_sha256 &&
  absentHash proposal.next_artifact_revision

def transition (state : State) (proposal : Proposal) : Option State :=
  match state.phase, proposal.event with
  | .candidate, .requestVerification
  | .repaired, .requestVerification =>
      if presentHash proposal.provider_authorization_sha256 &&
          noSemanticEvidence proposal && noRepairProposal proposal &&
          noArtifactReplacement proposal then
        some { state with
          phase := .verificationRequested
          transition_revision := state.transition_revision + 1
          active_provider_authorization_sha256 :=
            proposal.provider_authorization_sha256
          semantic_verdict_sha256 := zeroHash
          defect_sha256 := zeroHash
          repair_proposal_sha256 := zeroHash }
      else none
  | .verificationRequested, .markVerified =>
      if noProviderEvidence proposal &&
          presentHash proposal.semantic_verdict_sha256 &&
          absentHash proposal.defect_sha256 && noRepairProposal proposal &&
          noArtifactReplacement proposal then
        some { state with
          phase := .verified
          transition_revision := state.transition_revision + 1
          active_provider_authorization_sha256 := zeroHash
          semantic_verdict_sha256 := proposal.semantic_verdict_sha256 }
      else none
  | .verificationRequested, .reportDefect =>
      if noProviderEvidence proposal &&
          presentHash proposal.semantic_verdict_sha256 &&
          presentHash proposal.defect_sha256 && noRepairProposal proposal &&
          noArtifactReplacement proposal then
        some { state with
          phase := .defectFound
          transition_revision := state.transition_revision + 1
          active_provider_authorization_sha256 := zeroHash
          semantic_verdict_sha256 := proposal.semantic_verdict_sha256
          defect_sha256 := proposal.defect_sha256 }
      else none
  | .defectFound, .authorizeRepair =>
      if state.repair_attempts < state.max_repair_attempts &&
          presentHash proposal.provider_authorization_sha256 &&
          absentHash proposal.semantic_verdict_sha256 &&
          absentHash proposal.defect_sha256 &&
          presentHash proposal.repair_proposal_sha256 &&
          noArtifactReplacement proposal then
        some { state with
          phase := .repairAuthorized
          transition_revision := state.transition_revision + 1
          active_provider_authorization_sha256 :=
            proposal.provider_authorization_sha256
          repair_proposal_sha256 := proposal.repair_proposal_sha256 }
      else none
  | .repairAuthorized, .recordRepair =>
      if noProviderEvidence proposal && noSemanticEvidence proposal &&
          noRepairProposal proposal &&
          presentHash proposal.next_artifact_sha256 &&
          presentHash proposal.next_artifact_revision &&
          proposal.next_artifact_sha256 != state.artifact_sha256 &&
          proposal.next_artifact_revision != state.artifact_revision &&
          state.repair_attempts < state.max_repair_attempts then
        some { state with
          phase := .repaired
          artifact_sha256 := proposal.next_artifact_sha256
          artifact_revision := proposal.next_artifact_revision
          transition_revision := state.transition_revision + 1
          repair_attempts := state.repair_attempts + 1
          active_provider_authorization_sha256 := zeroHash
          semantic_verdict_sha256 := zeroHash
          defect_sha256 := zeroHash
          repair_proposal_sha256 := zeroHash }
      else none
  | .defectFound, .abandon =>
      if state.repair_attempts >= state.max_repair_attempts &&
          noProviderEvidence proposal &&
          absentHash proposal.semantic_verdict_sha256 &&
          absentHash proposal.defect_sha256 && noRepairProposal proposal &&
          noArtifactReplacement proposal then
        some { state with
          phase := .failed
          transition_revision := state.transition_revision + 1 }
      else none
  | _, _ => none

def providerAuthorizationCheck (request : Request) : Bool :=
  match request.proposal.event with
  | .requestVerification | .authorizeRepair =>
      presentHash request.proposal.provider_authorization_sha256
  | .markVerified | .reportDefect | .recordRepair =>
      presentHash request.state.active_provider_authorization_sha256 &&
      noProviderEvidence request.proposal
  | .abandon => noProviderEvidence request.proposal

def repairBudgetCheck (request : Request) : Bool :=
  match request.proposal.event with
  | .authorizeRepair | .recordRepair =>
      request.state.repair_attempts < request.state.max_repair_attempts
  | .abandon => request.state.repair_attempts >= request.state.max_repair_attempts
  | _ => true

def reverifyCheck (request : Request) : Bool :=
  match request.state.phase with
  | .repaired => decide (request.proposal.event = .requestVerification)
  | _ => true

def artifactAdvanceCheck (request : Request) : Bool :=
  match request.proposal.event with
  | .recordRepair =>
    presentHash request.proposal.next_artifact_sha256 &&
    presentHash request.proposal.next_artifact_revision &&
    request.proposal.next_artifact_sha256 != request.state.artifact_sha256 &&
    request.proposal.next_artifact_revision != request.state.artifact_revision
  | _ => true

def transitionWellFormed (request : Request) : Bool :=
  match transition request.state request.proposal with
  | some next =>
      decide (request.proposal.expected_next_phase = next.phase) &&
      stateWellFormed next
  | none => false

def SafeTransition (request : Request) : Bool :=
  requestBindingsValid request && stateWellFormed request.state &&
  proposalBound request && providerAuthorizationCheck request &&
  repairBudgetCheck request && reverifyCheck request &&
  artifactAdvanceCheck request &&
  transitionWellFormed request

theorem safeTransition_sound (request : Request)
    (admitted : SafeTransition request = true) :
    requestBindingsValid request = true ∧
    stateWellFormed request.state = true ∧
    proposalBound request = true ∧
    providerAuthorizationCheck request = true ∧
    repairBudgetCheck request = true ∧
    reverifyCheck request = true ∧
    artifactAdvanceCheck request = true ∧
    transitionWellFormed request = true := by
  simp [SafeTransition] at admitted
  simpa only [and_assoc] using admitted

theorem admitted_provider_request_is_bound_to_authorization
    (request : Request) (admitted : SafeTransition request = true)
    (event : request.proposal.event = .requestVerification ∨
      request.proposal.event = .authorizeRepair) :
    presentHash request.proposal.provider_authorization_sha256 = true := by
  have checked := (safeTransition_sound request admitted).2.2.2.1
  rcases event with event | event <;>
    simp [providerAuthorizationCheck, event] at checked <;> assumption

theorem admitted_provider_result_follows_authorized_state
    (request : Request) (admitted : SafeTransition request = true)
    (event : request.proposal.event = .markVerified ∨
      request.proposal.event = .reportDefect ∨
      request.proposal.event = .recordRepair) :
    presentHash request.state.active_provider_authorization_sha256 = true := by
  have checked := (safeTransition_sound request admitted).2.2.2.1
  rcases event with event | event
  · simp [providerAuthorizationCheck, event] at checked
    exact checked.1
  · rcases event with event | event <;>
      simp [providerAuthorizationCheck, event] at checked <;> exact checked.1

theorem admitted_repaired_state_requires_reverification
    (request : Request) (admitted : SafeTransition request = true)
    (phase : request.state.phase = .repaired) :
    request.proposal.event = .requestVerification := by
  have checked := (safeTransition_sound request admitted).2.2.2.2.2.1
  unfold reverifyCheck at checked
  rw [phase] at checked
  simp at checked
  exact checked

theorem admitted_record_repair_advances_artifact
    (request : Request) (admitted : SafeTransition request = true)
    (event : request.proposal.event = .recordRepair) :
    request.proposal.next_artifact_sha256 ≠ request.state.artifact_sha256 ∧
    request.proposal.next_artifact_revision ≠ request.state.artifact_revision := by
  have checked := (safeTransition_sound request admitted).2.2.2.2.2.2.1
  unfold artifactAdvanceCheck at checked
  rw [event] at checked
  simp at checked
  exact ⟨checked.1.2, checked.2⟩

theorem admitted_transition_produces_well_formed_state
    (request : Request) (admitted : SafeTransition request = true)
    (next : State) (applied : transition request.state request.proposal = some next) :
    stateWellFormed next = true := by
  have checked := (safeTransition_sound request admitted).2.2.2.2.2.2.2
  simp [transitionWellFormed, applied] at checked
  exact checked.2

theorem admitted_transition_binds_expected_next_phase
    (request : Request) (admitted : SafeTransition request = true)
    (next : State) (applied : transition request.state request.proposal = some next) :
    request.proposal.expected_next_phase = next.phase := by
  have checked := (safeTransition_sound request admitted).2.2.2.2.2.2.2
  simp [transitionWellFormed, applied] at checked
  exact checked.1

def failureCodes (request : Request) : List String :=
  let failures := if requestBindingsValid request then []
    else ["artifact_request_binding_invalid"]
  let failures := if stateWellFormed request.state then failures
    else failures ++ ["artifact_state_invalid"]
  let failures := if proposalBound request then failures
    else failures ++ ["artifact_revision_not_bound"]
  let failures := if providerAuthorizationCheck request then failures
    else failures ++ ["artifact_provider_not_authorized"]
  let failures := if repairBudgetCheck request then failures
    else failures ++ ["artifact_repair_budget_exhausted"]
  let failures := if reverifyCheck request then failures
    else failures ++ ["artifact_reverification_required"]
  let failures := if artifactAdvanceCheck request then failures
    else failures ++ ["artifact_not_advanced"]
  if transitionWellFormed request then failures
    else failures ++ ["artifact_transition_illegal"]

def checksJson (request : Request) : String :=
  "{" ++
  "\"bindings_valid\":" ++ boolJson (requestBindingsValid request) ++ "," ++
  "\"state_well_formed\":" ++ boolJson (stateWellFormed request.state) ++ "," ++
  "\"revision_advances\":" ++ boolJson (proposalBound request) ++ "," ++
  "\"provider_authorized\":" ++ boolJson (providerAuthorizationCheck request) ++ "," ++
  "\"repair_budget_preserved\":" ++ boolJson (repairBudgetCheck request) ++ "," ++
  "\"reverification_required\":" ++ boolJson (reverifyCheck request) ++ "," ++
  "\"artifact_advanced\":" ++ boolJson (artifactAdvanceCheck request) ++ "," ++
  "\"event_legal\":" ++ boolJson (transitionWellFormed request) ++
  "}"

def nextPhaseName (request : Request) : String :=
  match transition request.state request.proposal with
  | some state => Phase.encode state.phase
  | none => Phase.encode request.state.phase

def verdictJson (request : Request) : String :=
  let admitted := SafeTransition request
  "{" ++
  "\"schema_version\":\"" ++ verdictSchema ++ "\"," ++
  "\"checker_version\":\"" ++ checkerVersion ++ "\"," ++
  "\"request_id\":\"" ++ request.request_id ++ "\"," ++
  "\"operation\":\"" ++ request.operation ++ "\"," ++
  "\"proposal_sha256\":\"" ++ request.proposal_sha256 ++ "\"," ++
  "\"snapshot_sha256\":\"" ++ request.snapshot_sha256 ++ "\"," ++
  "\"snapshot_revision\":\"" ++ request.snapshot_revision ++ "\"," ++
  "\"decision\":\"" ++ (if admitted then "admit" else "block") ++ "\"," ++
  "\"admitted\":" ++ boolJson admitted ++ "," ++
  "\"next_phase\":\"" ++ nextPhaseName request ++ "\"," ++
  "\"next_snapshot_revision\":\"" ++ request.proposal.next_snapshot_revision ++ "\"," ++
  "\"reason_codes\":" ++ reasonCodesJson (failureCodes request) ++ "," ++
  "\"checks\":" ++ checksJson request ++
  "}"

def parsePhaseField (cursor : Cursor) (name : String) : Except String (Phase × Cursor) := do
  let (raw, cursor) ← parseStringField cursor name
  match Phase.decode raw with
  | some phase => pure (phase, cursor)
  | none => throw s!"unsupported artifact phase: {raw}"

def parseEventField (cursor : Cursor) (name : String) : Except String (EventKind × Cursor) := do
  let (raw, cursor) ← parseStringField cursor name
  match EventKind.decode raw with
  | some event => pure (event, cursor)
  | none => throw s!"unsupported artifact event: {raw}"

def decodeCanonicalRequest (input : String) : Except String Request := do
  let cursor : Cursor := { remaining := input.toList }
  let cursor ← expectLiteral cursor "{\"schema_version\":"
  let (schema_version, cursor) ← parseString cursor
  let cursor ← expectLiteral cursor ","
  let (request_id, cursor) ← parseStringField cursor "request_id"
  let cursor ← expectLiteral cursor ","
  let (operation, cursor) ← parseStringField cursor "operation"
  let cursor ← expectLiteral cursor ","
  let (proposal_sha256, cursor) ← parseStringField cursor "proposal_sha256"
  let cursor ← expectLiteral cursor ","
  let (snapshot_sha256, cursor) ← parseStringField cursor "snapshot_sha256"
  let cursor ← expectLiteral cursor ","
  let (snapshot_revision, cursor) ← parseStringField cursor "snapshot_revision"
  let cursor ← expectLiteral cursor ","
  let (expected_checker_version, cursor) ←
    parseStringField cursor "expected_checker_version"
  let cursor ← expectLiteral cursor ",\"state\":{"
  let (phase, cursor) ← parsePhaseField cursor "phase"
  let cursor ← expectLiteral cursor ","
  let (task_sha256, cursor) ← parseStringField cursor "task_sha256"
  let cursor ← expectLiteral cursor ","
  let (actor_run_sha256, cursor) ← parseStringField cursor "actor_run_sha256"
  let cursor ← expectLiteral cursor ","
  let (artifact_sha256, cursor) ← parseStringField cursor "artifact_sha256"
  let cursor ← expectLiteral cursor ","
  let (artifact_revision, cursor) ← parseStringField cursor "artifact_revision"
  let cursor ← expectLiteral cursor ","
  let (verifier_sha256, cursor) ← parseStringField cursor "verifier_sha256"
  let cursor ← expectLiteral cursor ","
  let (policy_sha256, cursor) ← parseStringField cursor "policy_sha256"
  let cursor ← expectLiteral cursor ","
  let (budget_authority_sha256, cursor) ←
    parseStringField cursor "budget_authority_sha256"
  let cursor ← expectLiteral cursor ","
  let (active_provider_authorization_sha256, cursor) ←
    parseStringField cursor "active_provider_authorization_sha256"
  let cursor ← expectLiteral cursor ","
  let (transition_revision, cursor) ← parseNatField cursor "transition_revision"
  let cursor ← expectLiteral cursor ","
  let (repair_attempts, cursor) ← parseNatField cursor "repair_attempts"
  let cursor ← expectLiteral cursor ","
  let (max_repair_attempts, cursor) ← parseNatField cursor "max_repair_attempts"
  let cursor ← expectLiteral cursor ","
  let (semantic_verdict_sha256, cursor) ←
    parseStringField cursor "semantic_verdict_sha256"
  let cursor ← expectLiteral cursor ","
  let (defect_sha256, cursor) ← parseStringField cursor "defect_sha256"
  let cursor ← expectLiteral cursor ","
  let (repair_proposal_sha256, cursor) ←
    parseStringField cursor "repair_proposal_sha256"
  let cursor ← expectLiteral cursor "},\"proposal\":{"
  let (event, cursor) ← parseEventField cursor "event"
  let cursor ← expectLiteral cursor ","
  let (expected_phase, cursor) ← parsePhaseField cursor "expected_phase"
  let cursor ← expectLiteral cursor ","
  let (expected_next_phase, cursor) ←
    parsePhaseField cursor "expected_next_phase"
  let cursor ← expectLiteral cursor ","
  let (expected_snapshot_revision, cursor) ←
    parseStringField cursor "expected_snapshot_revision"
  let cursor ← expectLiteral cursor ","
  let (next_snapshot_revision, cursor) ←
    parseStringField cursor "next_snapshot_revision"
  let cursor ← expectLiteral cursor ","
  let (provider_authorization_sha256, cursor) ←
    parseStringField cursor "provider_authorization_sha256"
  let cursor ← expectLiteral cursor ","
  let (proposal_verdict_sha256, cursor) ←
    parseStringField cursor "semantic_verdict_sha256"
  let cursor ← expectLiteral cursor ","
  let (proposal_defect_sha256, cursor) ← parseStringField cursor "defect_sha256"
  let cursor ← expectLiteral cursor ","
  let (proposal_repair_sha256, cursor) ←
    parseStringField cursor "repair_proposal_sha256"
  let cursor ← expectLiteral cursor ","
  let (next_artifact_sha256, cursor) ← parseStringField cursor "next_artifact_sha256"
  let cursor ← expectLiteral cursor ","
  let (next_artifact_revision, cursor) ←
    parseStringField cursor "next_artifact_revision"
  let cursor ← expectLiteral cursor "}}"
  if !cursor.remaining.isEmpty then throw "trailing bytes after artifact request"
  let state : State := {
    phase, task_sha256, actor_run_sha256, artifact_sha256, artifact_revision,
    verifier_sha256, policy_sha256, budget_authority_sha256,
    active_provider_authorization_sha256,
    transition_revision, repair_attempts, max_repair_attempts,
    semantic_verdict_sha256, defect_sha256, repair_proposal_sha256
  }
  let proposal : Proposal := {
    event, expected_phase, expected_next_phase,
    expected_snapshot_revision, next_snapshot_revision,
    provider_authorization_sha256,
    semantic_verdict_sha256 := proposal_verdict_sha256,
    defect_sha256 := proposal_defect_sha256,
    repair_proposal_sha256 := proposal_repair_sha256,
    next_artifact_sha256, next_artifact_revision
  }
  let request : Request := {
    schema_version, request_id, operation, proposal_sha256, snapshot_sha256,
    snapshot_revision, expected_checker_version, state, proposal
  }
  if request.schema_version != requestSchema then throw "unsupported request schema"
  if request.operation != "artifact_transition" then throw "unsupported operation"
  if request.expected_checker_version != checkerVersion then throw "checker version mismatch"
  let hashes := [request.request_id, request.proposal_sha256, request.snapshot_sha256,
    request.snapshot_revision, state.task_sha256, state.actor_run_sha256,
    state.artifact_sha256, state.artifact_revision, state.verifier_sha256,
    state.policy_sha256, state.budget_authority_sha256,
    state.active_provider_authorization_sha256,
    state.semantic_verdict_sha256, state.defect_sha256,
    state.repair_proposal_sha256, proposal.expected_snapshot_revision,
    proposal.next_snapshot_revision, proposal.provider_authorization_sha256,
    proposal.semantic_verdict_sha256, proposal.defect_sha256,
    proposal.repair_proposal_sha256, proposal.next_artifact_sha256,
    proposal.next_artifact_revision]
  if !hashes.all validLowerHex64 then
    throw "artifact bindings must be 64 lowercase hex characters"
  pure request

end MetaCodesControl.ArtifactVerification
