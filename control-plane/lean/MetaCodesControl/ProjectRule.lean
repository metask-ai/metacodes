import Std

namespace MetaCodesControl.ProjectRule

def specSchema : String := "metacodes-project-rule-spec-v1"

inductive EffectRequirement where
  | none
  | fileMutationV1Reobserved
  deriving Repr, BEq, DecidableEq

structure RuleSpec where
  targetTool : String
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
  0 < spec.maxInputBytes && spec.maxInputBytes ≤ 16 * 1024 * 1024 &&
  spec.maxAgentDepth ≤ 16 &&
  (!spec.denyTarget || spec.effectRequirement == .none)

def preDecision (spec : RuleSpec) (signal : PreSignal) : Bool :=
  if signal.tool != spec.targetTool then true
  else if spec.denyTarget then false
  else signal.inputBytes ≤ spec.maxInputBytes &&
    signal.agentDepth ≤ spec.maxAgentDepth &&
    (!spec.authoritativeOnly || signal.authoritative)

def postDecision (spec : RuleSpec) (signal : PostSignal) : Bool :=
  if signal.pre.tool != spec.targetTool then true
  else if !preDecision spec signal.pre then false
  else if !signal.succeeded then true
  else match spec.effectRequirement with
    | .none => true
    | .fileMutationV1Reobserved =>
        signal.effectValid && signal.hasFileMutationV1 && signal.postReobserved

theorem denied_target_blocks (spec : RuleSpec) (signal : PreSignal)
    (same : signal.tool = spec.targetTool) (denied : spec.denyTarget = true) :
    preDecision spec signal = false := by
  simp [preDecision, same, denied]

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

def effectName : EffectRequirement → String
  | .none => "none"
  | .fileMutationV1Reobserved => "file_mutation_v1_reobserved"

def boolJson (value : Bool) : String := if value then "true" else "false"

/-- Candidate build exports this byte-stable representation.  The host compares
it to the proposal's canonical JSON before issuing a build receipt. -/
def renderCanonical (spec : RuleSpec) : String :=
  "{" ++
  "\"schema_version\":\"" ++ specSchema ++ "\"," ++
  "\"target_tool\":\"" ++ spec.targetTool ++ "\"," ++
  "\"deny_target\":" ++ boolJson spec.denyTarget ++ "," ++
  "\"max_input_bytes\":" ++ toString spec.maxInputBytes ++ "," ++
  "\"max_agent_depth\":" ++ toString spec.maxAgentDepth ++ "," ++
  "\"authoritative_only\":" ++ boolJson spec.authoritativeOnly ++ "," ++
  "\"effect_requirement\":\"" ++ effectName spec.effectRequirement ++ "\"}"

end MetaCodesControl.ProjectRule
