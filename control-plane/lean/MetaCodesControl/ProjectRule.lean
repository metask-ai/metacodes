import Std

namespace MetaCodesControl.ProjectRule

def specSchema : String := "metacodes-project-rule-spec-v3"

inductive EffectRequirement where
  | none
  | fileMutationV1Reobserved
  deriving Repr, BEq, DecidableEq

inductive TargetScope where
  | all
  | existingFile
  deriving Repr, BEq, DecidableEq

/-- A governed effect class names the *outcome* a rule is about, so one rule
covers every tool that can produce it.  Tool-name targeting alone let an
advisory plane route the same effect through an uncovered tool.  The class is
a closed enum for the same reason `TargetScope` is: the fixed kernel, not
candidate Lean source, owns the applicability predicate. -/
inductive EffectClass where
  | existingFileRewrite
  deriving Repr, BEq, DecidableEq

/-- What a rule targets: one concrete tool by name, or one governed effect
class.  The union replaces the old bare `targetTool : String`; a rule cannot
be simultaneously tool- and effect-scoped, and there is no sentinel name. -/
inductive RuleTarget where
  | tool (name : String)
  | effectClass (cls : EffectClass)
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
  target : RuleTarget
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
  /-- State of the EFFECTIVE mutation target: the host resolves symlinks
  before classifying, so this describes the file whose bytes would actually
  change, never the path handle the model happened to use.  Resolution
  invariance is therefore by construction — the kernel has no handle field
  to look at.  (Field adjudication: a proven fail-closed block on the
  mkdocs `docs/index.md -> README.md` symlink was a false intervention;
  the policy error was judging the handle, not the effective target.) -/
  fileTargetState : FileTargetState := .unobserved
  /-- Host-observed containment: the RESOLVED target lies inside the project
  root.  A symlink escaping the root keeps failing closed regardless of the
  resolved state — the original escape protection, now explicit. -/
  withinRoot : Bool := true
  exactRecoveryMaterialReady : Bool := false
  /-- Host-owned fact: the dispatched tool's primary operation mutates a
  single observed file target.  The kernel cannot know the tool roster; it
  trusts this bit exactly the way it trusts `fileTargetState`.  Opaque tools
  (Bash) stay `false` and remain outside effect-class coverage. -/
  fileMutating : Bool := false
  deriving Repr, BEq

structure RecoveryPreSignal where
  tool : String
  inputBytes : Nat
  agentDepth : Nat
  authoritative : Bool
  targetMatches : Bool
  materialAvailable : Bool
  currentMatchesSource : Bool
  oldMatchesCurrent : Bool
  newMatchesBlocked : Bool
  deriving Repr, BEq

structure RecoveryPostSignal where
  pre : RecoveryPreSignal
  succeeded : Bool
  effectValid : Bool
  hasFileMutationV1 : Bool
  postReobserved : Bool
  observedMatchesBlocked : Bool
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
def validTarget (spec : RuleSpec) : Bool :=
  match spec.target with
  | .tool name =>
      !name.isEmpty && name.length ≤ 128 &&
        (spec.targetScope != .existingFile || name == "Write")
  | .effectClass _ =>
      -- The class itself encodes the file-state condition; a scope on top
      -- would double-encode it.  Deny is a phase restriction: deny-on-class
      -- would also deny the exact-edit recovery rail (the rail ends in an
      -- Edit, which matches the class), and a deny without a recovery
      -- protocol manufactures escape routes.  Until deny carries a
      -- class-shaped recovery design, effect-class rules verify only.
      spec.targetScope == .all && !spec.denyTarget

def valid (spec : RuleSpec) : Bool :=
  validTarget spec &&
  0 < spec.maxInputBytes && spec.maxInputBytes ≤ 16 * 1024 * 1024 &&
  spec.maxAgentDepth ≤ 16 &&
  (!spec.denyTarget || spec.effectRequirement == .none)

/-- Matched-dispatch decision.  Deny rules block.  Verify-only rules admit:
their obligations bind at post time, and the input/depth bounds are the rule
author's *reasoned envelope*, not a safety verdict — conflating the two blocked
a legitimate 14KB new-file deliverable twice in independent paid runs and
pushed the model into an ungoverned Bash escape.  Exceeding the envelope is
reported by the host as a bounds-overflow observation, never enforced here.
`authoritativeOnly` is a trust boundary, not a resource bound, and keeps its
gating role. -/
def matchedDecision (spec : RuleSpec) (signal : PreSignal) : Bool :=
  if spec.denyTarget then false
  else !spec.authoritativeOnly || signal.authoritative

/-- The reasoned envelope, exceeded.  Host instrumentation keys on this; it
must never influence `preDecision`/`postDecision`. -/
def boundsOverflow (spec : RuleSpec) (signal : PreSignal) : Bool :=
  signal.inputBytes > spec.maxInputBytes ||
    signal.agentDepth > spec.maxAgentDepth

/-- True when this dispatch is one the rule is *about*.  Static pruning must
key on this predicate — not on the tool-name string — and
`target_mismatch_admits_both` proves pruning on its negation is
semantics-preserving. -/
def targetMatchesPre (spec : RuleSpec) (signal : PreSignal) : Bool :=
  match spec.target with
  | .tool name => signal.tool == name
  | .effectClass .existingFileRewrite => signal.fileMutating

def preDecision (spec : RuleSpec) (signal : PreSignal) : Bool :=
  if !targetMatchesPre spec signal then true
  else match spec.target with
    | .tool _ => match spec.targetScope with
      | .all => matchedDecision spec signal
      | .existingFile =>
        if !signal.withinRoot then false
        else match signal.fileTargetState with
          | .missing => true
          | .regularExisting => matchedDecision spec signal
          | .unobserved | .otherExisting | .unavailable => false
    | .effectClass .existingFileRewrite =>
      -- Same conservative ladder as the existingFile scope: a mutating tool
      -- over an ambiguous target state cannot be proven not to be rewriting
      -- an existing file, so it fails closed.  Containment is judged first:
      -- an effective target outside the project root never admits.
      if !signal.withinRoot then false
      else match signal.fileTargetState with
        | .missing => true
        | .regularExisting => matchedDecision spec signal
        | .unobserved | .otherExisting | .unavailable => false

def postDecision (spec : RuleSpec) (signal : PostSignal) : Bool :=
  if !targetMatchesPre spec signal.pre then true
  else if !preDecision spec signal.pre then false
  else if !signal.succeeded then true
  else match spec.effectRequirement with
    | .none => true
    | .fileMutationV1Reobserved =>
        signal.effectValid && signal.hasFileMutationV1 && signal.postReobserved

def supportsExactEditRecovery (spec : RuleSpec) : Bool :=
  valid spec &&
    (match spec.target with
      | .tool name => name == "Write"
      | .effectClass _ => false) &&
    spec.targetScope == .existingFile && spec.denyTarget

def recoveryPreDecision (spec : RuleSpec) (signal : RecoveryPreSignal) : Bool :=
  supportsExactEditRecovery spec && signal.tool == "Edit" &&
    signal.inputBytes ≤ spec.maxInputBytes &&
    signal.agentDepth ≤ spec.maxAgentDepth &&
    (!spec.authoritativeOnly || signal.authoritative) &&
    signal.targetMatches && signal.materialAvailable &&
    signal.currentMatchesSource && signal.oldMatchesCurrent &&
    signal.newMatchesBlocked

/-- A malformed exact Edit may receive the same bounded retry direction only
while the blocked Write's source snapshot is still current. Source drift
invalidates the obligation and must not be presented as a retryable typo. -/
def recoveryPreRetryEligible (spec : RuleSpec) (signal : RecoveryPreSignal) : Bool :=
  supportsExactEditRecovery spec && signal.tool == "Edit" &&
    signal.inputBytes ≤ spec.maxInputBytes &&
    signal.agentDepth ≤ spec.maxAgentDepth &&
    (!spec.authoritativeOnly || signal.authoritative) &&
    signal.targetMatches && signal.materialAvailable &&
    signal.currentMatchesSource

def recoveryPostDecision (spec : RuleSpec) (signal : RecoveryPostSignal) : Bool :=
  if !recoveryPreDecision spec signal.pre then false
  else if !signal.effectValid then false
  else if !signal.succeeded then
    !signal.hasFileMutationV1 ||
      (signal.postReobserved && signal.observedMatchesBlocked)
  else signal.hasFileMutationV1 && signal.postReobserved &&
    signal.observedMatchesBlocked

/-- A denied overwrite of a host-observed regular file has one general safe
recovery direction: edit the existing bytes exactly.  Ambiguous targets,
invalid specifications and non-deny rules deliberately receive no hint. -/
def recoveryAction (spec : RuleSpec) (signal : PreSignal) : RecoveryAction :=
  match spec.targetScope, signal.fileTargetState with
  | .existingFile, .regularExisting =>
      if supportsExactEditRecovery spec &&
          targetMatchesPre spec signal && !preDecision spec signal then
        if signal.exactRecoveryMaterialReady then .editExistingFileExact else .none
      else
        .none
  | _, _ => .none

/-- The doubly-reproduced WorkBuddy false intervention, made impossible: a
verify-only rule admits a matched dispatch even when the input exceeds the
authored envelope.  The obligation still binds at post time. -/
theorem verify_only_bounds_overflow_admits (spec : RuleSpec) (signal : PreSignal)
    (target : spec.target = .tool signal.tool)
    (scope : spec.targetScope = .all)
    (verify_only : spec.denyTarget = false)
    (authority : !spec.authoritativeOnly || signal.authoritative = true)
    (_overflow : boundsOverflow spec signal = true) :
    preDecision spec signal = true := by
  cases h : spec.authoritativeOnly with
  | false => simp [preDecision, targetMatchesPre, matchedDecision, target,
      scope, verify_only, h]
  | true =>
      have auth : signal.authoritative = true := by
        simpa [h] using authority
      simp [preDecision, targetMatchesPre, matchedDecision, target, scope,
        verify_only, h, auth]

theorem denied_all_target_blocks (spec : RuleSpec) (signal : PreSignal)
    (target : spec.target = .tool signal.tool) (scope : spec.targetScope = .all)
    (denied : spec.denyTarget = true) :
    preDecision spec signal = false := by
  simp [preDecision, targetMatchesPre, matchedDecision, target, scope, denied]

theorem denied_existing_file_blocks_regular (spec : RuleSpec) (signal : PreSignal)
    (target : spec.target = .tool signal.tool)
    (scope : spec.targetScope = .existingFile)
    (state : signal.fileTargetState = .regularExisting)
    (denied : spec.denyTarget = true) :
    preDecision spec signal = false := by
  simp [preDecision, targetMatchesPre, matchedDecision, target, scope, state,
    denied]

theorem existing_file_scope_allows_missing (spec : RuleSpec) (signal : PreSignal)
    (target : spec.target = .tool signal.tool)
    (scope : spec.targetScope = .existingFile)
    (state : signal.fileTargetState = .missing)
    (within : signal.withinRoot = true) :
    preDecision spec signal = true := by
  simp [preDecision, targetMatchesPre, target, scope, state, within]

theorem existing_file_scope_fails_closed_without_regular_observation
    (spec : RuleSpec) (signal : PreSignal)
    (target : spec.target = .tool signal.tool)
    (scope : spec.targetScope = .existingFile)
    (uncertain : signal.fileTargetState = .unobserved ∨
      signal.fileTargetState = .otherExisting ∨
      signal.fileTargetState = .unavailable) :
    preDecision spec signal = false := by
  rcases uncertain with state | state | state <;>
    simp [preDecision, targetMatchesPre, target, scope, state]

/-- The host may erase rules whose target predicate does not hold for the
concrete pre signal before invoking the sidecar.  This is a
semantics-preserving fast path, not a second authorization policy: both
fixed-kernel decisions are definitionally `true` whenever the target does not
match.  This generalizes the retired `target_tool_mismatch_admits_both`: the
predicate is `targetMatchesPre`, which covers effect-class targets too. -/
theorem target_mismatch_admits_both (spec : RuleSpec) (signal : PostSignal)
    (different : targetMatchesPre spec signal.pre = false) :
    preDecision spec signal.pre = true ∧ postDecision spec signal = true := by
  simp [preDecision, postDecision, different]

theorem reobservation_required (spec : RuleSpec) (signal : PostSignal)
    (matched : targetMatchesPre spec signal.pre = true)
    (pre : preDecision spec signal.pre = true)
    (succeeded : signal.succeeded = true)
    (required : spec.effectRequirement = .fileMutationV1Reobserved)
    (admitted : postDecision spec signal = true) :
    signal.effectValid = true ∧ signal.hasFileMutationV1 = true ∧
      signal.postReobserved = true := by
  simp [postDecision, matched, pre, succeeded, required] at admitted
  simpa only [and_assoc] using admitted

theorem effect_class_matches_any_mutating_tool (spec : RuleSpec)
    (signal : PreSignal)
    (target : spec.target = .effectClass .existingFileRewrite)
    (mutating : signal.fileMutating = true) :
    targetMatchesPre spec signal = true := by
  simp [targetMatchesPre, target, mutating]

theorem effect_class_ignores_opaque_tools (spec : RuleSpec) (signal : PostSignal)
    (target : spec.target = .effectClass .existingFileRewrite)
    (opaqueTool : signal.pre.fileMutating = false) :
    preDecision spec signal.pre = true ∧ postDecision spec signal = true := by
  refine target_mismatch_admits_both spec signal ?_
  simp [targetMatchesPre, target, opaqueTool]

theorem effect_class_allows_proven_new_file (spec : RuleSpec)
    (signal : PreSignal)
    (target : spec.target = .effectClass .existingFileRewrite)
    (state : signal.fileTargetState = .missing)
    (within : signal.withinRoot = true) :
    preDecision spec signal = true := by
  cases hm : signal.fileMutating with
  | false => simp [preDecision, targetMatchesPre, target, hm]
  | true => simp [preDecision, targetMatchesPre, target, hm, state, within]

/-- Containment is judged before anything else: an effective target outside
the project root never admits, whatever its resolved state or evidence.  The
original symlink-escape protection, now an explicit theorem. -/
theorem escaping_resolution_fails_closed (spec : RuleSpec)
    (signal : PreSignal)
    (target : spec.target = .effectClass .existingFileRewrite)
    (mutating : signal.fileMutating = true)
    (escape : signal.withinRoot = false) :
    preDecision spec signal = false := by
  simp [preDecision, targetMatchesPre, target, mutating, escape]

/-- The adjudicated false intervention as a proven positive: a mutating tool
whose EFFECTIVE target resolves to a regular file inside the project root
admits under a verify-only rule.  A symlink handle to such a file is exactly
this signal, so the mkdocs `docs/index.md -> README.md` read-then-edit can
never be blocked again by a rule this kernel checks. -/
theorem resolved_regular_within_root_admits (spec : RuleSpec)
    (signal : PreSignal)
    (target : spec.target = .effectClass .existingFileRewrite)
    (mutating : signal.fileMutating = true)
    (state : signal.fileTargetState = .regularExisting)
    (within : signal.withinRoot = true)
    (verify_only : spec.denyTarget = false)
    (trusted : spec.authoritativeOnly = false) :
    preDecision spec signal = true := by
  simp [preDecision, targetMatchesPre, matchedDecision, target, mutating,
    state, within, verify_only, trusted]

theorem effect_class_fails_closed_on_ambiguous_target (spec : RuleSpec)
    (signal : PreSignal)
    (target : spec.target = .effectClass .existingFileRewrite)
    (mutating : signal.fileMutating = true)
    (uncertain : signal.fileTargetState = .unobserved ∨
      signal.fileTargetState = .otherExisting ∨
      signal.fileTargetState = .unavailable) :
    preDecision spec signal = false := by
  rcases uncertain with state | state | state <;>
    simp [preDecision, targetMatchesPre, target, mutating, state]

/-- Deny on an effect class is structurally unrepresentable in a valid spec.
Whoever lifts the phase restriction must replace this theorem with the
class-shaped recovery design, not merely delete it. -/
theorem effect_class_cannot_deny (spec : RuleSpec) (cls : EffectClass)
    (target : spec.target = .effectClass cls)
    (validSpec : valid spec = true) :
    spec.denyTarget = false := by
  cases hd : spec.denyTarget with
  | false => rfl
  | true =>
      exfalso
      simp [valid, validTarget, target, hd] at validSpec

theorem denied_observed_overwrite_selects_exact_edit_recovery
    (spec : RuleSpec) (signal : PreSignal)
    (validSpec : valid spec = true)
    (target : spec.target = .tool "Write")
    (scope : spec.targetScope = .existingFile)
    (denied : spec.denyTarget = true)
    (same : signal.tool = "Write")
    (state : signal.fileTargetState = .regularExisting)
    (material : signal.exactRecoveryMaterialReady = true) :
    recoveryAction spec signal = .editExistingFileExact := by
  simp [recoveryAction, validSpec, target, scope, denied, same, state,
    material, supportsExactEditRecovery, targetMatchesPre, preDecision,
    matchedDecision]
  decide

theorem nonregular_target_has_no_exact_edit_recovery
    (spec : RuleSpec) (signal : PreSignal)
    (nonregular : signal.fileTargetState = .unobserved ∨
      signal.fileTargetState = .missing ∨
      signal.fileTargetState = .otherExisting ∨
      signal.fileTargetState = .unavailable) :
    recoveryAction spec signal = .none := by
  rcases nonregular with state | state | state | state <;>
    simp [recoveryAction, state]

theorem exact_edit_recovery_pre_sound (spec : RuleSpec)
    (signal : RecoveryPreSignal)
    (admitted : recoveryPreDecision spec signal = true) :
    signal.targetMatches = true ∧ signal.materialAvailable = true ∧
      signal.currentMatchesSource = true ∧ signal.oldMatchesCurrent = true ∧
      signal.newMatchesBlocked = true := by
  simp [recoveryPreDecision] at admitted
  exact ⟨admitted.1.1.1.1.2, admitted.1.1.1.2,
    admitted.1.1.2, admitted.1.2, admitted.2⟩

theorem exact_edit_recovery_post_sound (spec : RuleSpec)
    (signal : RecoveryPostSignal)
    (succeeded : signal.succeeded = true)
    (admitted : recoveryPostDecision spec signal = true) :
    signal.effectValid = true ∧ signal.hasFileMutationV1 = true ∧
      signal.postReobserved = true ∧ signal.observedMatchesBlocked = true := by
  simp [recoveryPostDecision, succeeded] at admitted
  exact ⟨admitted.2.1, admitted.2.2.1.1, admitted.2.2.1.2,
    admitted.2.2.2⟩

theorem exact_edit_recovery_failed_mutation_sound (spec : RuleSpec)
    (signal : RecoveryPostSignal)
    (failed : signal.succeeded = false)
    (mutated : signal.hasFileMutationV1 = true)
    (admitted : recoveryPostDecision spec signal = true) :
    signal.effectValid = true ∧ signal.postReobserved = true ∧
      signal.observedMatchesBlocked = true := by
  simp [recoveryPostDecision, failed, mutated] at admitted
  exact ⟨admitted.2.1, admitted.2.2.1, admitted.2.2.2⟩

def recoveryReasonCode : RecoveryAction → Option String
  | .none => none
  | .editExistingFileExact => some "recover_edit_existing_file_exact"

def effectName : EffectRequirement → String
  | .none => "none"
  | .fileMutationV1Reobserved => "file_mutation_v1_reobserved"

def scopeName : TargetScope → String
  | .all => "all"
  | .existingFile => "existing_file"

def effectClassName : EffectClass → String
  | .existingFileRewrite => "existing_file_rewrite"

def targetKindName : RuleTarget → String
  | .tool _ => "tool"
  | .effectClass _ => "effect_class"

def targetName : RuleTarget → String
  | .tool name => name
  | .effectClass cls => effectClassName cls

def boolJson (value : Bool) : String := if value then "true" else "false"

/-- Candidate build exports this byte-stable representation.  The host compares
it to the proposal's canonical JSON before issuing a build receipt.  Field
order mirrors the Zig `Wire` struct declaration order exactly. -/
def renderCanonical (spec : RuleSpec) : String :=
  "{" ++
  "\"schema_version\":\"" ++ specSchema ++ "\"," ++
  "\"target_kind\":\"" ++ targetKindName spec.target ++ "\"," ++
  "\"target\":\"" ++ targetName spec.target ++ "\"," ++
  "\"target_scope\":\"" ++ scopeName spec.targetScope ++ "\"," ++
  "\"deny_target\":" ++ boolJson spec.denyTarget ++ "," ++
  "\"max_input_bytes\":" ++ toString spec.maxInputBytes ++ "," ++
  "\"max_agent_depth\":" ++ toString spec.maxAgentDepth ++ "," ++
  "\"authoritative_only\":" ++ boolJson spec.authoritativeOnly ++ "," ++
  "\"effect_requirement\":\"" ++ effectName spec.effectRequirement ++ "\"}"

end MetaCodesControl.ProjectRule
