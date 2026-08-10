import Std

namespace MetaCodesControl.ProjectRule

def specSchema : String := "metacodes-project-rule-spec-v2"

inductive EffectRequirement where
  | none
  | fileMutationV1Reobserved
  deriving Repr, BEq, DecidableEq

inductive TargetScope where
  | all
  | existingFile
  deriving Repr, BEq, DecidableEq

inductive FileTargetState where
  | unobserved
  | missing
  | regularExisting
  | otherExisting
  | unavailable
  deriving Repr, BEq, DecidableEq

/-- A bounded recovery direction emitted only after the fixed kernel has
blocked a concrete pre-dispatch signal.  This is not an authorization: the
replacement tool still traverses the ordinary sensor, kernel and reobservation
path. -/
inductive RecoveryAction where
  | none
  | editExistingFileExact
  deriving Repr, BEq, DecidableEq

structure RuleSpec where
  targetTool : String
  targetScope : TargetScope := .all
  denyTarget : Bool
  maxInputBytes : Nat
  maxAgentDepth : Nat
  authoritativeOnly : Bool
  effectRequirement : EffectRequirement
  deriving Repr, BEq

structure PreSignal where
  tool : String
  inputBytes : Nat
  agentDepth : Nat
  authoritative : Bool
  fileTargetState : FileTargetState := .unobserved
  deriving Repr, BEq

structure PostSignal where
  pre : PreSignal
  succeeded : Bool
  effectValid : Bool
  hasFileMutationV1 : Bool
  postReobserved : Bool
  deriving Repr, BEq

/-- String byte syntax is checked independently by the Zig/Python decoders.
Keeping host encoding validation outside this predicate lets candidate proofs
remain axiom-free: Std's optimized Char classification currently introduces
`propext` into `#print axioms` even for a closed `rfl` proof. -/
def valid (spec : RuleSpec) : Bool :=
  !spec.targetTool.isEmpty && spec.targetTool.length ≤ 128 &&
  (spec.targetScope != .existingFile || spec.targetTool == "Write") &&
  0 < spec.maxInputBytes && spec.maxInputBytes ≤ 16 * 1024 * 1024 &&
  spec.maxAgentDepth ≤ 16 &&
  (!spec.denyTarget || spec.effectRequirement == .none)

def matchedDecision (spec : RuleSpec) (signal : PreSignal) : Bool :=
  if spec.denyTarget then false
  else signal.inputBytes ≤ spec.maxInputBytes &&
    signal.agentDepth ≤ spec.maxAgentDepth &&
    (!spec.authoritativeOnly || signal.authoritative)

def preDecision (spec : RuleSpec) (signal : PreSignal) : Bool :=
  if signal.tool != spec.targetTool then true
  else match spec.targetScope with
    | .all => matchedDecision spec signal
    | .existingFile => match signal.fileTargetState with
      | .missing => true
      | .regularExisting => matchedDecision spec signal
      | .unobserved | .otherExisting | .unavailable => false

def postDecision (spec : RuleSpec) (signal : PostSignal) : Bool :=
  if signal.pre.tool != spec.targetTool then true
  else if !preDecision spec signal.pre then false
  else if !signal.succeeded then true
  else match spec.effectRequirement with
    | .none => true
    | .fileMutationV1Reobserved =>
        signal.effectValid && signal.hasFileMutationV1 && signal.postReobserved

/-- A denied overwrite of a host-observed regular file has one general safe
recovery direction: edit the existing bytes exactly.  Ambiguous targets,
invalid specifications and non-deny rules deliberately receive no hint. -/
def recoveryAction (spec : RuleSpec) (signal : PreSignal) : RecoveryAction :=
  match spec.targetScope, signal.fileTargetState with
  | .existingFile, .regularExisting =>
      if valid spec && spec.targetTool == "Write" && spec.denyTarget &&
          signal.tool == spec.targetTool && !preDecision spec signal then
        .editExistingFileExact
      else
        .none
  | _, _ => .none

theorem denied_all_target_blocks (spec : RuleSpec) (signal : PreSignal)
    (same : signal.tool = spec.targetTool) (scope : spec.targetScope = .all)
    (denied : spec.denyTarget = true) :
    preDecision spec signal = false := by
  simp [preDecision, matchedDecision, same, scope, denied]

theorem denied_existing_file_blocks_regular (spec : RuleSpec) (signal : PreSignal)
    (same : signal.tool = spec.targetTool)
    (scope : spec.targetScope = .existingFile)
    (state : signal.fileTargetState = .regularExisting)
    (denied : spec.denyTarget = true) :
    preDecision spec signal = false := by
  simp [preDecision, matchedDecision, same, scope, state, denied]

theorem existing_file_scope_allows_missing (spec : RuleSpec) (signal : PreSignal)
    (same : signal.tool = spec.targetTool)
    (scope : spec.targetScope = .existingFile)
    (state : signal.fileTargetState = .missing) :
    preDecision spec signal = true := by
  simp [preDecision, same, scope, state]

theorem existing_file_scope_fails_closed_without_regular_observation
    (spec : RuleSpec) (signal : PreSignal)
    (same : signal.tool = spec.targetTool)
    (scope : spec.targetScope = .existingFile)
    (uncertain : signal.fileTargetState = .unobserved ∨
      signal.fileTargetState = .otherExisting ∨
      signal.fileTargetState = .unavailable) :
    preDecision spec signal = false := by
  rcases uncertain with state | state | state <;>
    simp [preDecision, same, scope, state]

theorem reobservation_required (spec : RuleSpec) (signal : PostSignal)
    (same : signal.pre.tool = spec.targetTool)
    (pre : preDecision spec signal.pre = true)
    (succeeded : signal.succeeded = true)
    (required : spec.effectRequirement = .fileMutationV1Reobserved)
    (admitted : postDecision spec signal = true) :
    signal.effectValid = true ∧ signal.hasFileMutationV1 = true ∧
      signal.postReobserved = true := by
  simp [postDecision, same, pre, succeeded, required] at admitted
  simpa only [and_assoc] using admitted

theorem denied_observed_overwrite_selects_exact_edit_recovery
    (spec : RuleSpec) (signal : PreSignal)
    (validSpec : valid spec = true)
    (target : spec.targetTool = "Write")
    (scope : spec.targetScope = .existingFile)
    (denied : spec.denyTarget = true)
    (same : signal.tool = spec.targetTool)
    (state : signal.fileTargetState = .regularExisting) :
    recoveryAction spec signal = .editExistingFileExact := by
  simp [recoveryAction, validSpec, target, scope, denied, same, state,
    preDecision, matchedDecision]

theorem nonregular_target_has_no_exact_edit_recovery
    (spec : RuleSpec) (signal : PreSignal)
    (nonregular : signal.fileTargetState = .unobserved ∨
      signal.fileTargetState = .missing ∨
      signal.fileTargetState = .otherExisting ∨
      signal.fileTargetState = .unavailable) :
    recoveryAction spec signal = .none := by
  rcases nonregular with state | state | state | state <;>
    simp [recoveryAction, state]

def recoveryReasonCode : RecoveryAction → Option String
  | .none => none
  | .editExistingFileExact => some "recover_edit_existing_file_exact"

def effectName : EffectRequirement → String
  | .none => "none"
  | .fileMutationV1Reobserved => "file_mutation_v1_reobserved"

def scopeName : TargetScope → String
  | .all => "all"
  | .existingFile => "existing_file"

def boolJson (value : Bool) : String := if value then "true" else "false"

/-- Candidate build exports this byte-stable representation.  The host compares
it to the proposal's canonical JSON before issuing a build receipt. -/
def renderCanonical (spec : RuleSpec) : String :=
  "{" ++
  "\"schema_version\":\"" ++ specSchema ++ "\"," ++
  "\"target_tool\":\"" ++ spec.targetTool ++ "\"," ++
  "\"target_scope\":\"" ++ scopeName spec.targetScope ++ "\"," ++
  "\"deny_target\":" ++ boolJson spec.denyTarget ++ "," ++
  "\"max_input_bytes\":" ++ toString spec.maxInputBytes ++ "," ++
  "\"max_agent_depth\":" ++ toString spec.maxAgentDepth ++ "," ++
  "\"authoritative_only\":" ++ boolJson spec.authoritativeOnly ++ "," ++
  "\"effect_requirement\":\"" ++ effectName spec.effectRequirement ++ "\"}"

end MetaCodesControl.ProjectRule
