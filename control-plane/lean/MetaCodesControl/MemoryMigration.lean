import MetaCodesControl.FormalKernel

namespace MetaCodesControl.MemoryMigration

open MetaCodesControl.FormalKernel

def requestSchema : String := "metacodes-memory-migration-request-v1"

inductive MemoryKind where
  | observation
  | decision
  | userPreference
  | concept
  | document
  | verification
  | task
  | project
  deriving Repr, BEq

def MemoryKind.decode : String → Option MemoryKind
  | "observation" => some .observation
  | "decision" => some .decision
  | "user_preference" => some .userPreference
  | "concept" => some .concept
  | "document" => some .document
  | "verification" => some .verification
  | "task" => some .task
  | "project" => some .project
  | _ => none

def MemoryKind.supersedable : MemoryKind → Bool
  | .observation | .decision | .userPreference | .concept | .document => true
  | .verification | .task | .project => false

structure NodeView where
  id : Nat
  kind : MemoryKind
  schema_type : String
  current_generation : Bool
  retrieval_excluded : Bool
  contradicted : Bool
  deriving Repr, BEq

/--
This is a minimal, role-addressed snapshot rather than an LLM-provided list of
preservation booleans.  TinyKG must produce all three records under one store
lock and bind them to `snapshot_revision` before the host invokes this kernel.
-/
structure Snapshot where
  bounded : Bool
  truncated : Bool
  source : NodeView
  replacement : NodeView
  evidence : NodeView
  deprecated_edge_exists : Bool
  deriving Repr, BEq

structure Proposal where
  source_id : Nat
  replacement_id : Nat
  evidence_id : Nat
  effect : String
  rollback : String
  snapshot_revision : String
  deriving Repr, BEq

structure Request where
  schema_version : String
  request_id : String
  operation : String
  proposal_sha256 : String
  snapshot_sha256 : String
  snapshot_revision : String
  expected_checker_version : String
  snapshot : Snapshot
  proposal : Proposal
  deriving Repr

/-- Abstract state touched by the executor for this migration primitive. -/
structure GraphState where
  nodes : List NodeView
  deprecated_by : List (Nat × Nat)
  retrieval_excluded : List Nat
  deriving Repr, BEq

def applySupersede (state : GraphState) (proposal : Proposal) : GraphState :=
  { state with
    deprecated_by := (proposal.source_id, proposal.replacement_id) :: state.deprecated_by
    retrieval_excluded := proposal.source_id :: state.retrieval_excluded }

def rollbackSupersede (state : GraphState) (proposal : Proposal) : GraphState :=
  { state with
    deprecated_by := state.deprecated_by.erase (proposal.source_id, proposal.replacement_id)
    retrieval_excluded := state.retrieval_excluded.erase proposal.source_id }

def fixedEffect (proposal : Proposal) : Bool :=
  proposal.effect == "add_deprecated_by_and_exclude_source" &&
  proposal.rollback == "remove_deprecated_by_and_restore_source"

def referencesValid (snapshot : Snapshot) (proposal : Proposal) : Bool :=
  proposal.source_id == snapshot.source.id &&
  proposal.replacement_id == snapshot.replacement.id &&
  proposal.evidence_id == snapshot.evidence.id &&
  snapshot.source.id != snapshot.replacement.id &&
  snapshot.source.id != snapshot.evidence.id &&
  snapshot.replacement.id != snapshot.evidence.id

def generationsValid (snapshot : Snapshot) : Bool :=
  snapshot.source.current_generation &&
  snapshot.replacement.current_generation &&
  snapshot.evidence.current_generation

def validSchemaType (value : String) : Bool :=
  !value.isEmpty && value.length <= 64 && value.toList.all fun char =>
    ('a' ≤ char && char ≤ 'z') || ('A' ≤ char && char ≤ 'Z') ||
    ('0' ≤ char && char ≤ '9') || char == '_' || char == '-' ||
    char == ':' || char == '.'

def schemaPreserved (snapshot : Snapshot) : Bool :=
  snapshot.source.kind.supersedable &&
  validSchemaType snapshot.source.schema_type &&
  validSchemaType snapshot.replacement.schema_type &&
  validSchemaType snapshot.evidence.schema_type &&
  snapshot.replacement.kind == snapshot.source.kind &&
  snapshot.replacement.schema_type == snapshot.source.schema_type

def evidenceValid (snapshot : Snapshot) : Bool :=
  snapshot.evidence.kind == .verification && !snapshot.evidence.contradicted

def contradictionSafe (snapshot : Snapshot) : Bool :=
  !snapshot.replacement.contradicted

def reversiblePreconditions (snapshot : Snapshot) : Bool :=
  !snapshot.deprecated_edge_exists && !snapshot.source.retrieval_excluded

/--
The first mutating governance rule.  Unlike the read-only task audit, the
caller cannot assert `preserves_*` booleans.  Every gate below is computed from
the observed node records and the fixed operation semantics.
-/
def requestBindingsValid (request : Request) : Bool :=
  request.schema_version == requestSchema &&
  request.operation == "memory_supersede_existing" &&
  request.expected_checker_version == checkerVersion &&
  validLowerHex64 request.request_id &&
  validLowerHex64 request.proposal_sha256 &&
  validLowerHex64 request.snapshot_sha256 &&
  validLowerHex64 request.snapshot_revision

def migrationObligations (request : Request) : Bool :=
  request.proposal.snapshot_revision == request.snapshot_revision &&
  request.snapshot.bounded && !request.snapshot.truncated &&
  fixedEffect request.proposal &&
  referencesValid request.snapshot request.proposal &&
  generationsValid request.snapshot &&
  schemaPreserved request.snapshot &&
  evidenceValid request.snapshot &&
  contradictionSafe request.snapshot &&
  !request.snapshot.replacement.retrieval_excluded &&
  reversiblePreconditions request.snapshot

def SafeSupersede (request : Request) : Bool :=
  requestBindingsValid request && migrationObligations request

/-- Admission exposes every runtime precondition used by the fixed mutation. -/
theorem safeSupersede_sound (request : Request)
    (admitted : SafeSupersede request = true) :
    request.proposal.snapshot_revision = request.snapshot_revision ∧
    request.snapshot.bounded = true ∧
    request.snapshot.truncated = false ∧
    fixedEffect request.proposal = true ∧
    referencesValid request.snapshot request.proposal = true ∧
    generationsValid request.snapshot = true ∧
    schemaPreserved request.snapshot = true ∧
    evidenceValid request.snapshot = true ∧
    contradictionSafe request.snapshot = true ∧
    request.snapshot.replacement.retrieval_excluded = false ∧
    reversiblePreconditions request.snapshot = true := by
  have obligations := admitted
  simp [SafeSupersede] at obligations
  have structural := obligations.2
  simp [migrationObligations] at structural
  simpa only [and_assoc] using structural

/-- The modeled mutation cannot alter task, evidence, or any other node. -/
theorem applySupersede_preserves_nodes (state : GraphState) (proposal : Proposal) :
    (applySupersede state proposal).nodes = state.nodes := by
  rfl

/-- Under the checked freshness preconditions, rollback is an exact inverse. -/
theorem rollbackSupersede_apply (state : GraphState) (proposal : Proposal) :
    rollbackSupersede (applySupersede state proposal) proposal = state := by
  simp [applySupersede, rollbackSupersede]

def failureCodes (request : Request) : List String :=
  let failures := if request.proposal.snapshot_revision == request.snapshot_revision then []
    else ["proposal_not_bound"]
  let failures := if request.snapshot.bounded then failures
    else failures ++ ["snapshot_unbounded"]
  let failures := if !request.snapshot.truncated then failures
    else failures ++ ["snapshot_truncated"]
  let failures := if fixedEffect request.proposal then failures
    else failures ++ ["unsupported_memory_effect"]
  let failures := if referencesValid request.snapshot request.proposal then failures
    else failures ++ ["invalid_reference"]
  let failures := if generationsValid request.snapshot then failures
    else failures ++ ["stale_memory_generation"]
  let failures := if schemaPreserved request.snapshot then failures
    else failures ++ ["schema_not_preserved"]
  let failures := if evidenceValid request.snapshot then failures
    else failures ++ ["migration_evidence_invalid"]
  let failures := if contradictionSafe request.snapshot then failures
    else failures ++ ["contradiction_promoted"]
  let failures := if !request.snapshot.replacement.retrieval_excluded then failures
    else failures ++ ["replacement_excluded"]
  if reversiblePreconditions request.snapshot then failures
    else failures ++ ["proposal_not_reversible"]

def checksJson (request : Request) : String :=
  "{" ++
  "\"snapshot_usable\":" ++ boolJson
    (request.snapshot.bounded && !request.snapshot.truncated) ++ "," ++
  "\"proposal_well_formed\":" ++ boolJson (fixedEffect request.proposal) ++ "," ++
  "\"references_valid\":" ++ boolJson
    (referencesValid request.snapshot request.proposal) ++ "," ++
  -- The fixed executor semantics only add one edge and one retrieval marker;
  -- `applySupersede_preserves_nodes` proves tasks/evidence cannot be removed.
  "\"tasks_preserved\":true," ++
  "\"evidence_preserved\":" ++ boolJson (evidenceValid request.snapshot) ++ "," ++
  "\"recovery_preserved\":" ++ boolJson
    (reversiblePreconditions request.snapshot) ++ "," ++
  "\"schema_preserved\":" ++ boolJson (schemaPreserved request.snapshot) ++ "," ++
  "\"contradiction_safe\":" ++ boolJson (contradictionSafe request.snapshot) ++ "," ++
  "\"reversible\":" ++ boolJson (reversiblePreconditions request.snapshot) ++
  "}"

def verdictJson (request : Request) : String :=
  let admitted := SafeSupersede request
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
  "\"reason_codes\":" ++ reasonCodesJson (failureCodes request) ++ "," ++
  "\"checks\":" ++ checksJson request ++
  "}"

def parseKindField (cursor : Cursor) (name : String) : Except String (MemoryKind × Cursor) := do
  let (raw, cursor) ← parseStringField cursor name
  match MemoryKind.decode raw with
  | some kind => pure (kind, cursor)
  | none => throw s!"unsupported memory kind: {raw}"

def parseNodeView (cursor : Cursor) : Except String (NodeView × Cursor) := do
  let cursor ← expectLiteral cursor "{"
  let (id, cursor) ← parseNatField cursor "id"
  let cursor ← expectLiteral cursor ","
  let (kind, cursor) ← parseKindField cursor "kind"
  let cursor ← expectLiteral cursor ","
  let (schema_type, cursor) ← parseStringField cursor "schema_type"
  let cursor ← expectLiteral cursor ","
  let (current_generation, cursor) ← parseBoolField cursor "current_generation"
  let cursor ← expectLiteral cursor ","
  let (retrieval_excluded, cursor) ← parseBoolField cursor "retrieval_excluded"
  let cursor ← expectLiteral cursor ","
  let (contradicted, cursor) ← parseBoolField cursor "contradicted"
  let cursor ← expectLiteral cursor "}"
  if id == 0 then throw "node id must be positive"
  if schema_type.isEmpty || schema_type.length > 64 then
    throw "schema_type length is outside protocol bounds"
  pure ({ id, kind, schema_type, current_generation, retrieval_excluded, contradicted }, cursor)

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
  let cursor ← expectLiteral cursor ",\"snapshot\":{"
  let (bounded, cursor) ← parseBoolField cursor "bounded"
  let cursor ← expectLiteral cursor ","
  let (truncated, cursor) ← parseBoolField cursor "truncated"
  let cursor ← expectLiteral cursor ",\"source\":"
  let (source, cursor) ← parseNodeView cursor
  let cursor ← expectLiteral cursor ",\"replacement\":"
  let (replacement, cursor) ← parseNodeView cursor
  let cursor ← expectLiteral cursor ",\"evidence\":"
  let (evidence, cursor) ← parseNodeView cursor
  let cursor ← expectLiteral cursor ","
  let (deprecated_edge_exists, cursor) ←
    parseBoolField cursor "deprecated_edge_exists"
  let cursor ← expectLiteral cursor "},\"proposal\":{"
  let (source_id, cursor) ← parseNatField cursor "source_id"
  let cursor ← expectLiteral cursor ","
  let (replacement_id, cursor) ← parseNatField cursor "replacement_id"
  let cursor ← expectLiteral cursor ","
  let (evidence_id, cursor) ← parseNatField cursor "evidence_id"
  let cursor ← expectLiteral cursor ","
  let (effect, cursor) ← parseStringField cursor "effect"
  let cursor ← expectLiteral cursor ","
  let (rollback, cursor) ← parseStringField cursor "rollback"
  let cursor ← expectLiteral cursor ","
  let (proposal_revision, cursor) ← parseStringField cursor "snapshot_revision"
  let cursor ← expectLiteral cursor "}}"
  if !cursor.remaining.isEmpty then throw "trailing bytes after formal request"
  let request : Request := {
    schema_version, request_id, operation, proposal_sha256, snapshot_sha256,
    snapshot_revision, expected_checker_version,
    snapshot := {
      bounded, truncated, source, replacement, evidence, deprecated_edge_exists
    },
    proposal := {
      source_id, replacement_id, evidence_id, effect, rollback,
      snapshot_revision := proposal_revision
    }
  }
  if request.schema_version != requestSchema then throw "unsupported request schema"
  if request.operation != "memory_supersede_existing" then throw "unsupported operation"
  if request.expected_checker_version != checkerVersion then throw "checker version mismatch"
  if !validLowerHex64 request.request_id ||
      !validLowerHex64 request.proposal_sha256 ||
      !validLowerHex64 request.snapshot_sha256 ||
      !validLowerHex64 request.snapshot_revision then
    throw "request bindings must be 64 lowercase hex characters"
  pure request

end MetaCodesControl.MemoryMigration
