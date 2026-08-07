import MetaCodesControl.ClosedLoop

namespace MetaCodesControl.PaidBudgetJournal

open MetaCodesControl.ClosedLoop

/-- The two independent dimensions governed by the paid-evaluation authority. -/
structure Amount where
  costMicrousd : Nat
  meteredTokens : Nat
  deriving Repr, DecidableEq, BEq

def Amount.add (left right : Amount) : Amount := {
  costMicrousd := left.costMicrousd + right.costMicrousd
  meteredTokens := left.meteredTokens + right.meteredTokens
}

def Amount.within (value authority : Amount) : Bool :=
  value.costMicrousd <= authority.costMicrousd &&
  value.meteredTokens <= authority.meteredTokens

inductive Phase where
  | initial
  | reserved
  | requestAuthorized
  | committed
  | abortedPreRequest
  deriving Repr, DecidableEq, BEq

/--
Abstract identity material that the native journal binds into its transaction
id and hash-chain event.  `Nat` values stand for non-empty, validated protocol
identities; the repository sensor owns the concrete SHA-256 encoding contract.
-/
structure Identity where
  manifest : Nat
  run : Nat
  model : Nat
  harness : Nat
  provider : Nat
  journal : Nat
  transaction : Nat
  reservationRevision : Nat
  maximum : Amount
  authority : Amount
  deriving Repr, DecidableEq, BEq

def Identity.complete (identity : Identity) : Bool :=
  identity.manifest != 0 && identity.run != 0 && identity.model != 0 &&
  identity.harness != 0 && identity.provider != 0 && identity.journal != 0 &&
  identity.transaction != 0 && identity.reservationRevision != 0 &&
  identity.maximum.costMicrousd != 0 && identity.maximum.meteredTokens != 0 &&
  identity.authority.costMicrousd != 0 && identity.authority.meteredTokens != 0

structure TransactionState where
  phase : Phase
  identity : Identity
  actual : Amount
  authorizationPersisted : Bool
  authorizationRevision : Nat
  authorizationHead : Nat
  deriving Repr, DecidableEq, BEq

inductive Event where
  | reserve
  | persistAuthorization (revision : Nat) (head : Nat)
  | commit (actual : Amount)
  | abortPreRequest
  deriving Repr, DecidableEq, BEq

structure ProviderPermit where
  transaction : Nat
  authorizationRevision : Nat
  authorizationHead : Nat
  deriving Repr, DecidableEq, BEq

/-- Reserved and authorized requests expose their maximum; committed requests
expose actual use; an initial or safely aborted request exposes nothing. -/
def exposure (state : TransactionState) : Amount :=
  match state.phase with
  | .reserved | .requestAuthorized => state.identity.maximum
  | .committed => state.actual
  | .initial | .abortedPreRequest => { costMicrousd := 0, meteredTokens := 0 }

def withinAuthority
    (otherExposure authority : Amount) (state : TransactionState) : Bool :=
  (otherExposure.add (exposure state)).within authority

def identityBoundToAuthority
    (authority : Amount) (state : TransactionState) : Bool :=
  state.identity.complete && decide (state.identity.authority = authority)

def accept
    (otherExposure authority : Amount) (candidate : TransactionState) :
    Option TransactionState :=
  if withinAuthority otherExposure authority candidate then some candidate else none

theorem accept_some_eq
    (other authority : Amount) (candidate accepted : TransactionState)
    (admitted : accept other authority candidate = some accepted) :
    accepted = candidate := by
  simp only [accept] at admitted
  split at admitted <;> simp_all

/-- Canonical lifecycle projection. Amount and identity gates refine these
transitions but cannot introduce another phase edge. -/
def lifecycleTransition : Phase → Event → Option Phase
  | .initial, .reserve => some .reserved
  | .initial, .abortPreRequest => some .abortedPreRequest
  | .reserved, .persistAuthorization _ _ => some .requestAuthorized
  | .reserved, .abortPreRequest => some .abortedPreRequest
  | .requestAuthorized, .commit _ => some .committed
  | .committed, .commit _ => some .committed
  | _, _ => none

def durableAuthorizationAllowed
    (state : TransactionState) (revision head : Nat) : Bool :=
  revision > state.identity.reservationRevision && head != 0

def committedReplayAllowed (state : TransactionState) (actual : Amount) : Bool :=
  decide (state.phase = .committed) && decide (actual = state.actual)

/--
The machine deliberately has no authorized-to-reserved/aborted transition and
no second authorization transition.  An authorization event is admitted only
after its durable revision/head exist.  The native L2 proves those fields are
returned only after fsync/rename/parent-fsync completes.
-/
def candidateTransition
    (otherExposure authority : Amount) (state : TransactionState) (event : Event) :
    Option TransactionState :=
  match lifecycleTransition state.phase event, event with
  | some nextPhase, .reserve =>
      let candidate := {
        state with
        phase := nextPhase
        actual := { costMicrousd := 0, meteredTokens := 0 }
        authorizationPersisted := false
        authorizationRevision := 0
        authorizationHead := 0
      }
      if identityBoundToAuthority authority candidate then
        accept otherExposure authority candidate
      else
        none
  | some nextPhase, .abortPreRequest =>
      accept otherExposure authority {
        state with
        phase := nextPhase
        actual := { costMicrousd := 0, meteredTokens := 0 }
        authorizationPersisted := false
        authorizationRevision := 0
        authorizationHead := 0
      }
  | some nextPhase, .persistAuthorization revision head =>
      if durableAuthorizationAllowed state revision head then
        accept otherExposure authority {
          state with
          phase := nextPhase
          authorizationPersisted := true
          authorizationRevision := revision
          authorizationHead := head
        }
      else
        none
  | some nextPhase, .commit actual =>
      if state.phase = .requestAuthorized then
        if actual.within state.identity.maximum then
          accept otherExposure authority { state with phase := nextPhase, actual := actual }
        else
          none
      else if committedReplayAllowed state actual then
        some { state with phase := nextPhase }
      else
        none
  | _, _ => none

/-- The exported transition rechecks the complete two-dimensional exposure for
every successful branch, including a committed idempotent replay. -/
def transition
    (otherExposure authority : Amount) (state : TransactionState) (event : Event) :
    Option TransactionState :=
  match candidateTransition otherExposure authority state event with
  | none => none
  | some candidate => accept otherExposure authority candidate

/-- A provider attempt requires the exact persisted authorization receipt. -/
def providerRequestAllowed
    (state : TransactionState) (permit : Option ProviderPermit) : Bool :=
  match permit with
  | none => false
  | some permit =>
      decide (state.phase = .requestAuthorized) && state.authorizationPersisted &&
      permit.transaction == state.identity.transaction &&
      permit.authorizationRevision == state.authorizationRevision &&
      permit.authorizationHead == state.authorizationHead

theorem authorized_recovery_exposes_maximum
    (state : TransactionState) (authorized : state.phase = .requestAuthorized) :
    exposure state = state.identity.maximum := by
  simp [exposure, authorized]

theorem admitted_identity_is_complete_and_authority_bound
    (authority : Amount) (state : TransactionState)
    (admitted : identityBoundToAuthority authority state = true) :
    state.identity.complete = true ∧ state.identity.authority = authority := by
  simp [identityBoundToAuthority] at admitted
  exact admitted

theorem authorized_cannot_return_to_unrequested
    (event : Event) (next : Phase)
    (stepped : lifecycleTransition .requestAuthorized event = some next) :
    next = .committed := by
  cases event <;> simp_all [lifecycleTransition]

theorem repeated_authorization_is_rejected (revision head : Nat) :
    lifecycleTransition .requestAuthorized (.persistAuthorization revision head) = none := by
  simp [lifecycleTransition]

theorem admitted_authorization_has_new_revision_and_head
    (state : TransactionState) (revision head : Nat)
    (admitted : durableAuthorizationAllowed state revision head = true) :
    revision > state.identity.reservationRevision ∧ head ≠ 0 := by
  simp [durableAuthorizationAllowed] at admitted
  exact admitted

theorem committed_usage_is_idempotent
    (state : TransactionState) (committed : state.phase = .committed) :
    committedReplayAllowed state state.actual = true := by
  simp [committedReplayAllowed, committed]

theorem committed_usage_drift_is_rejected
    (state : TransactionState) (different : Amount)
    (drift : different ≠ state.actual) :
    committedReplayAllowed state different = false := by
  simp [committedReplayAllowed, drift]

theorem provider_request_requires_persisted_authorization
    (state : TransactionState) (permit : ProviderPermit)
    (allowed : providerRequestAllowed state (some permit) = true) :
    state.phase = .requestAuthorized ∧
    state.authorizationPersisted = true ∧
    permit.transaction = state.identity.transaction ∧
    permit.authorizationRevision = state.authorizationRevision ∧
    permit.authorizationHead = state.authorizationHead := by
  simp [providerRequestAllowed] at allowed
  simpa only [and_assoc] using allowed

theorem provider_request_without_persisted_authorization_is_rejected
    (state : TransactionState) (permit : Option ProviderPermit)
    (missing : state.authorizationPersisted = false) :
    providerRequestAllowed state permit = false := by
  cases permit <;> simp [providerRequestAllowed, missing]

theorem provider_request_without_permit_is_rejected (state : TransactionState) :
    providerRequestAllowed state none = false := by
  simp [providerRequestAllowed]

/-- Every accepted candidate is inside both dollar and token authority. -/
theorem accept_preserves_authority
    (other authority : Amount) (candidate accepted : TransactionState)
    (admitted : accept other authority candidate = some accepted) :
    withinAuthority other authority accepted = true := by
  simp only [accept] at admitted
  split at admitted
  · rename_i safe
    simp at admitted
    rw [← admitted]
    exact safe
  · simp at admitted

theorem successful_transition_preserves_total_authority
    (other authority : Amount) (state next : TransactionState) (event : Event)
    (stepped : transition other authority state event = some next) :
    withinAuthority other authority next = true := by
  simp only [transition] at stepped
  split at stepped
  · simp at stepped
  · exact accept_preserves_authority other authority _ next stepped

/-- Nine fixed repository obligations bind this model to the single-machine
production pilot.  A weakened 8/8 sensor cannot silently shrink the boundary. -/
def paidBudgetSignal
    (topology : Topology) (observation : Observation) : Signal :=
  if observation.declared == 9 then signal topology observation else .blockRelease

def paidBudgetNextState
    (topology : Topology) (observation : Observation) : RuleState :=
  match paidBudgetSignal topology observation with
  | .blockRelease => .blocked
  | .runFeedback => .verifying
  | .admitRelease => .compliant

def paidBudgetReleaseAllowed
    (topology : Topology) (observation : Observation) : Bool :=
  paidBudgetSignal topology observation == .admitRelease

theorem paid_budget_admitted_implies_nine_obligations
    (topology : Topology) (observation : Observation)
    (admitted : paidBudgetReleaseAllowed topology observation = true) :
    observation.declared = 9 ∧ observation.covered = 9 := by
  simp [paidBudgetReleaseAllowed, paidBudgetSignal] at admitted
  split at admitted
  · rename_i declaredNine
    have genericAdmitted : releaseAllowed topology observation = true := by
      simpa [releaseAllowed] using admitted
    have exact := admitted_implies_zero_deviation topology observation genericAdmitted
    omega
  · simp at admitted

theorem paid_budget_missing_obligation_blocks
    (topology : Topology) (observation : Observation)
    (declaresNine : observation.declared = 9)
    (missing : observation.covered < 9) :
    paidBudgetSignal topology observation = .blockRelease := by
  simp [paidBudgetSignal, declaresNine]
  apply missing_evidence_blocks topology observation
  omega

theorem paid_budget_wrong_cardinality_blocks
    (topology : Topology) (observation : Observation)
    (wrong : observation.declared ≠ 9) :
    paidBudgetSignal topology observation = .blockRelease := by
  simp [paidBudgetSignal, wrong]

end MetaCodesControl.PaidBudgetJournal
