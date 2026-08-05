import Std

namespace MetaCodesControl.FormalKernel

def requestSchema : String := "metacodes-formal-request-v1"
def verdictSchema : String := "metacodes-formal-verdict-v1"
def checkerVersion : String := "metacodes-formal-kernel-v1"

/--
Facts are measured by the Zig sensor from one bounded TinyKG snapshot.  The
kernel does not guess graph state and does not perform I/O beyond the versioned
request/response protocol.
-/
structure SafetyFacts where
  schema_supported : Bool
  snapshot_bounded : Bool
  task_count : Nat
  open_count : Nat
  claimed_count : Nat
  completed_count : Nat
  failed_count : Nat
  claimed_with_owner_count : Nat
  reachable_task_count : Nat
  terminal_with_evidence_count : Nat
  invalid_reference_count : Nat
  truncated : Bool
  proposal_bound : Bool
  preserves_tasks : Bool
  preserves_evidence : Bool
  preserves_recovery : Bool
  preserves_schema : Bool
  contradiction_safe : Bool
  reversible : Bool
  deriving Repr

structure Request where
  schema_version : String
  request_id : String
  operation : String
  proposal_sha256 : String
  snapshot_sha256 : String
  snapshot_revision : String
  expected_checker_version : String
  facts : SafetyFacts
  deriving Repr

def countsConsistent (facts : SafetyFacts) : Bool :=
  facts.task_count ==
    facts.open_count + facts.claimed_count + facts.completed_count + facts.failed_count

def claimsOwned (facts : SafetyFacts) : Bool :=
  facts.claimed_count == facts.claimed_with_owner_count

def hierarchyRecoverable (facts : SafetyFacts) : Bool :=
  facts.reachable_task_count == facts.task_count

def terminalEvidencePreserved (facts : SafetyFacts) : Bool :=
  facts.terminal_with_evidence_count == facts.completed_count + facts.failed_count

/--
The executable governance decision.  Future memory/schema migration operations
reuse the preservation obligations; `task_audit` is the first read-only
vertical and therefore proposes no destructive mutation.
-/
def SafeMigration (facts : SafetyFacts) : Bool :=
  facts.schema_supported && facts.snapshot_bounded && !facts.truncated &&
  countsConsistent facts && claimsOwned facts && hierarchyRecoverable facts &&
  terminalEvidencePreserved facts && facts.invalid_reference_count == 0 &&
  facts.proposal_bound && facts.preserves_tasks && facts.preserves_evidence &&
  facts.preserves_recovery && facts.preserves_schema && facts.contradiction_safe &&
  facts.reversible

/-- The runtime decision cannot admit while silently dropping an obligation. -/
theorem safeMigration_sound (facts : SafetyFacts)
    (admitted : SafeMigration facts = true) :
    facts.schema_supported = true ∧
    facts.snapshot_bounded = true ∧
    facts.truncated = false ∧
    facts.task_count =
      facts.open_count + facts.claimed_count + facts.completed_count + facts.failed_count ∧
    facts.claimed_count = facts.claimed_with_owner_count ∧
    facts.reachable_task_count = facts.task_count ∧
    facts.terminal_with_evidence_count = facts.completed_count + facts.failed_count ∧
    facts.invalid_reference_count = 0 ∧
    facts.proposal_bound = true ∧
    facts.preserves_tasks = true ∧
    facts.preserves_evidence = true ∧
    facts.preserves_recovery = true ∧
    facts.preserves_schema = true ∧
    facts.contradiction_safe = true ∧
    facts.reversible = true := by
  have obligations := admitted
  simp [SafeMigration, countsConsistent, claimsOwned, hierarchyRecoverable,
    terminalEvidencePreserved] at obligations
  simpa only [and_assoc] using obligations

def validLowerHex64 (value : String) : Bool :=
  value.length == 64 && value.toList.all fun char =>
    ('0' ≤ char && char ≤ '9') || ('a' ≤ char && char ≤ 'f')

def validateRequest (request : Request) : Except String Request := do
  if request.schema_version != requestSchema then
    throw "unsupported request schema"
  if request.operation != "task_audit" then
    throw "unsupported operation"
  if request.expected_checker_version != checkerVersion then
    throw "checker version mismatch"
  if !validLowerHex64 request.request_id then
    throw "request_id must be 64 lowercase hex characters"
  if !validLowerHex64 request.proposal_sha256 then
    throw "proposal_sha256 must be 64 lowercase hex characters"
  if !validLowerHex64 request.snapshot_sha256 then
    throw "snapshot_sha256 must be 64 lowercase hex characters"
  if !validLowerHex64 request.snapshot_revision then
    throw "snapshot_revision must be 64 lowercase hex characters"
  if request.facts.task_count > 4096 then throw "task_count exceeds protocol bound"
  if request.facts.invalid_reference_count > 8192 then
    throw "invalid_reference_count exceeds protocol bound"
  pure request

def failureCodes (facts : SafetyFacts) : List String :=
  let failures := if facts.schema_supported then [] else ["unsupported_snapshot_schema"]
  let failures := if facts.snapshot_bounded then failures else failures ++ ["snapshot_unbounded"]
  let failures := if !facts.truncated then failures else failures ++ ["snapshot_truncated"]
  let failures := if countsConsistent facts then failures else failures ++ ["lifecycle_count_mismatch"]
  let failures := if claimsOwned facts then failures else failures ++ ["claim_without_owner"]
  let failures := if hierarchyRecoverable facts then failures else failures ++ ["recovery_path_missing"]
  let failures := if terminalEvidencePreserved facts then failures else failures ++ ["terminal_evidence_missing"]
  let failures := if facts.invalid_reference_count == 0 then failures else failures ++ ["invalid_reference"]
  let failures := if facts.proposal_bound then failures else failures ++ ["proposal_not_bound"]
  let failures := if facts.preserves_tasks then failures else failures ++ ["tasks_not_preserved"]
  let failures := if facts.preserves_evidence then failures else failures ++ ["evidence_not_preserved"]
  let failures := if facts.preserves_recovery then failures else failures ++ ["recovery_not_preserved"]
  let failures := if facts.preserves_schema then failures else failures ++ ["schema_not_preserved"]
  let failures := if facts.contradiction_safe then failures else failures ++ ["contradiction_promoted"]
  if facts.reversible then failures else failures ++ ["proposal_not_reversible"]

def boolJson (value : Bool) : String := if value then "true" else "false"

def reasonCodesJson (codes : List String) : String :=
  "[" ++ String.intercalate "," (codes.map fun code => "\"" ++ code ++ "\"") ++ "]"

/--
The request parser below intentionally accepts one canonical JSON encoding,
not arbitrary JSON.  Zig owns serialization and all input values are bounded
ASCII booleans, naturals, enums, or SHA-256 digests.  Keeping that narrow
wire grammar avoids pulling Lean's compiler-facing JSON AST into the shipped
checker while still retaining a versioned, independently inspectable JSON
protocol.  Reordered, duplicated, unknown, escaped, or trailing fields fail
closed.
-/
structure Cursor where
  remaining : List Char

def expectLiteral (cursor : Cursor) (literal : String) : Except String Cursor :=
  let expected := literal.toList
  if cursor.remaining.take expected.length == expected then
    pure { remaining := cursor.remaining.drop expected.length }
  else
    throw s!"expected {literal}"

partial def takeQuotedChars (chars : List Char) (acc : List Char := []) :
    Except String (String × List Char) :=
  match chars with
  | [] => throw "unterminated JSON string"
  | '"' :: rest => pure (String.mk acc.reverse, rest)
  | '\\' :: _ => throw "JSON escapes are not permitted in canonical formal requests"
  | char :: rest =>
      if char.toNat < 0x20 || char.toNat > 0x7e then
        throw "formal request strings must contain printable ASCII"
      else
        takeQuotedChars rest (char :: acc)

def parseString (cursor : Cursor) : Except String (String × Cursor) := do
  let cursor ← expectLiteral cursor "\""
  let (value, rest) ← takeQuotedChars cursor.remaining
  pure (value, { remaining := rest })

partial def takeDigits (chars : List Char) (acc : List Char := []) :
    List Char × List Char :=
  match chars with
  | char :: rest =>
      if '0' ≤ char && char ≤ '9' then takeDigits rest (char :: acc)
      else (acc.reverse, chars)
  | [] => (acc.reverse, [])

def parseNat (cursor : Cursor) : Except String (Nat × Cursor) := do
  let (digits, rest) := takeDigits cursor.remaining
  if digits.isEmpty then throw "expected natural number"
  -- Counts are protocol-bounded below.  Bounding lexical width first prevents
  -- an oversized decimal from becoming a parser-level resource attack.
  if digits.length > 10 then throw "natural number exceeds lexical bound"
  match (String.mk digits).toNat? with
  | some value => pure (value, { remaining := rest })
  | none => throw "invalid natural number"

def parseBool (cursor : Cursor) : Except String (Bool × Cursor) :=
  if cursor.remaining.take 4 == "true".toList then
    pure (true, { remaining := cursor.remaining.drop 4 })
  else if cursor.remaining.take 5 == "false".toList then
    pure (false, { remaining := cursor.remaining.drop 5 })
  else
    throw "expected boolean"

def parseStringField (cursor : Cursor) (name : String) :
    Except String (String × Cursor) := do
  let cursor ← expectLiteral cursor ("\"" ++ name ++ "\":")
  parseString cursor

def parseNatField (cursor : Cursor) (name : String) :
    Except String (Nat × Cursor) := do
  let cursor ← expectLiteral cursor ("\"" ++ name ++ "\":")
  parseNat cursor

def parseBoolField (cursor : Cursor) (name : String) :
    Except String (Bool × Cursor) := do
  let cursor ← expectLiteral cursor ("\"" ++ name ++ "\":")
  parseBool cursor

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
  let cursor ← expectLiteral cursor ",\"facts\":{"
  let (schema_supported, cursor) ← parseBoolField cursor "schema_supported"
  let cursor ← expectLiteral cursor ","
  let (snapshot_bounded, cursor) ← parseBoolField cursor "snapshot_bounded"
  let cursor ← expectLiteral cursor ","
  let (task_count, cursor) ← parseNatField cursor "task_count"
  let cursor ← expectLiteral cursor ","
  let (open_count, cursor) ← parseNatField cursor "open_count"
  let cursor ← expectLiteral cursor ","
  let (claimed_count, cursor) ← parseNatField cursor "claimed_count"
  let cursor ← expectLiteral cursor ","
  let (completed_count, cursor) ← parseNatField cursor "completed_count"
  let cursor ← expectLiteral cursor ","
  let (failed_count, cursor) ← parseNatField cursor "failed_count"
  let cursor ← expectLiteral cursor ","
  let (claimed_with_owner_count, cursor) ←
    parseNatField cursor "claimed_with_owner_count"
  let cursor ← expectLiteral cursor ","
  let (reachable_task_count, cursor) ← parseNatField cursor "reachable_task_count"
  let cursor ← expectLiteral cursor ","
  let (terminal_with_evidence_count, cursor) ←
    parseNatField cursor "terminal_with_evidence_count"
  let cursor ← expectLiteral cursor ","
  let (invalid_reference_count, cursor) ←
    parseNatField cursor "invalid_reference_count"
  let cursor ← expectLiteral cursor ","
  let (truncated, cursor) ← parseBoolField cursor "truncated"
  let cursor ← expectLiteral cursor ","
  let (proposal_bound, cursor) ← parseBoolField cursor "proposal_bound"
  let cursor ← expectLiteral cursor ","
  let (preserves_tasks, cursor) ← parseBoolField cursor "preserves_tasks"
  let cursor ← expectLiteral cursor ","
  let (preserves_evidence, cursor) ← parseBoolField cursor "preserves_evidence"
  let cursor ← expectLiteral cursor ","
  let (preserves_recovery, cursor) ← parseBoolField cursor "preserves_recovery"
  let cursor ← expectLiteral cursor ","
  let (preserves_schema, cursor) ← parseBoolField cursor "preserves_schema"
  let cursor ← expectLiteral cursor ","
  let (contradiction_safe, cursor) ← parseBoolField cursor "contradiction_safe"
  let cursor ← expectLiteral cursor ","
  let (reversible, cursor) ← parseBoolField cursor "reversible"
  let cursor ← expectLiteral cursor "}}"
  if !cursor.remaining.isEmpty then throw "trailing bytes after formal request"
  validateRequest {
    schema_version, request_id, operation, proposal_sha256, snapshot_sha256,
    snapshot_revision, expected_checker_version,
    facts := {
      schema_supported, snapshot_bounded, task_count, open_count, claimed_count,
      completed_count, failed_count, claimed_with_owner_count,
      reachable_task_count, terminal_with_evidence_count,
      invalid_reference_count, truncated, proposal_bound, preserves_tasks,
      preserves_evidence, preserves_recovery, preserves_schema,
      contradiction_safe, reversible
    }
  }

def verdictJson (request : Request) : String :=
  let admitted := SafeMigration request.facts
  let obligations := request.facts.proposal_bound &&
    request.facts.preserves_tasks && request.facts.preserves_evidence &&
    request.facts.preserves_recovery && request.facts.preserves_schema &&
    request.facts.contradiction_safe && request.facts.reversible
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
  "\"reason_codes\":" ++ reasonCodesJson (failureCodes request.facts) ++ "," ++
  "\"checks\":{" ++
    "\"counts_consistent\":" ++ boolJson (countsConsistent request.facts) ++ "," ++
    "\"claims_owned\":" ++ boolJson (claimsOwned request.facts) ++ "," ++
    "\"hierarchy_recoverable\":" ++ boolJson (hierarchyRecoverable request.facts) ++ "," ++
    "\"terminal_evidence_preserved\":" ++ boolJson (terminalEvidencePreserved request.facts) ++ "," ++
    "\"references_valid\":" ++ boolJson (request.facts.invalid_reference_count == 0) ++ "," ++
    "\"preservation_obligations\":" ++ boolJson obligations ++
  "}}"

def decodeRequest (input : String) : Except String Request := do
  decodeCanonicalRequest input

end MetaCodesControl.FormalKernel
