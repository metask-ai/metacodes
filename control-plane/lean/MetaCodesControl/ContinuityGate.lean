import Std

/-! # Continuity integrity gates: formal policy (v42)

Forensics (p41): the version gate reads only header metadata, so a store
corrupted by the engine's delete/compaction path passes `store-info` with
intact version fields and then fails every scoped read with InvalidRecord —
the memory system dies silently, and the ungated export chain propagates the
poisoned store to the whole arm and every descendant seeded from it (15/16
trials lost memory; two further arms burned on the inherited seed).

Two gates close the hole:

* import side (`src/kg/client.zig` `deepProbeOrQuarantine`): after the
  version gate, one deep probe in the session's own read shape.  A
  data-class failure means the store is deterministically unreadable for
  this engine → quarantine (atomic rename, bytes preserved for forensics)
  and re-init fresh; the dose re-ingests from outcome roots, so the loss is
  bounded to store-only rows.  A transient failure never quarantines —
  environment jitter must not nuke memory.

* export side (adapter `store_export` + host advance decision): the export
  is probed in-container before the tar; the host advances
  `store-latest.tar` only on probe pass.  A rejected export is recorded in
  the ledger (degraded row, chain head sha unchanged) but never becomes the
  chain head.  A missing probe receipt fails closed.

Each theorem names the mirroring Zig/Python test. -/

namespace MetaCodesControl.ContinuityGate

inductive ProbeResult where
  | ok
  | dataFail
  | transientFail
  deriving Repr, DecidableEq

inductive ImportAction where
  | openStore
  | quarantineFresh
  | degraded
  deriving Repr, DecidableEq

/-- Import decision after the version gate.  Mirrors
`ensureReady` → `deepProbeOrQuarantine`. -/
def importAction (headerOk : Bool) (probe : ProbeResult) : ImportAction :=
  if !headerOk then .degraded
  else
    match probe with
    | .ok => .openStore
    | .dataFail => .quarantineFresh
    | .transientFail => .openStore

/-- A deterministically unreadable store is never opened as-is — the
session never runs a whole arm on dead memory.  Zig mirror: "deep probe
data failure quarantines the store and re-inits fresh". -/
theorem broken_store_never_opens (headerOk : Bool) :
    importAction headerOk .dataFail ≠ .openStore := by
  unfold importAction
  cases headerOk <;> simp

/-- Environment jitter never quarantines: only a data-class probe failure
can trigger the rename.  Zig mirror: "transient probe failure leaves the
store in place" (tail assertion of the quarantine test). -/
theorem transient_never_quarantines (headerOk : Bool) :
    importAction headerOk .transientFail ≠ .quarantineFresh := by
  unfold importAction
  cases headerOk <;> simp

/-- A healthy store is opened untouched — the gate is inert on the good
path. -/
theorem healthy_store_opens : importAction true .ok = .openStore := by rfl

/-- The version gate stays authoritative: with the header check failed no
probe outcome reaches quarantine or open. -/
theorem header_gate_first (probe : ProbeResult) :
    importAction false probe = .degraded := by rfl

/-- Dose recovery bound: after quarantine + fresh init the re-ingested dose
equals the outcome-root rows — the loss is exactly the store-only rows,
never the roots.  (The roots plane is host-side and untouched by store
corruption.) -/
def doseAfterQuarantine (rootRows _storeOnlyRows : Nat) : Nat := rootRows

theorem quarantine_loss_bounded (rootRows storeOnlyRows : Nat) :
    doseAfterQuarantine rootRows storeOnlyRows = rootRows := by rfl

/-- Export-side chain-head validity: the head after a trial is the new
export iff the probe passed, else the previous head.  Mirrors the adapter's
advance decision. -/
def headValid (prevValid probeOk : Bool) : Bool :=
  if probeOk then true else prevValid

/-- A probe-failed export never advances the chain: the head validity is
exactly the previous head's.  Python mirror:
`test_export_probe_failure_keeps_previous_tar_and_writes_degraded_row`. -/
theorem poison_stops_at_gate (prevValid : Bool) :
    headValid prevValid false = prevValid := by rfl

/-- Chain safety is monotone: a valid chain head can never degrade to a
poisoned one through any single trial — the gate admits only probed
exports.  This is the induction step that makes whole-arm safety follow
from a healthy seed. -/
theorem validity_monotone (probeOk : Bool) :
    headValid true probeOk = true := by
  cases probeOk <;> rfl

/-- The probe receipt fails closed: an rc file that is missing or unreadable
counts as a failed probe.  Python mirror:
`test_export_probe_receipt_missing_fails_closed`. -/
def probeOf (rcPresent rcZero : Bool) : Bool :=
  rcPresent && rcZero

theorem missing_receipt_never_advances (prevValid rcZero : Bool) :
    headValid prevValid (probeOf false rcZero) = prevValid := by
  cases rcZero <;> rfl

/-- A rejected export is recorded but inert: the degraded ledger row keeps
the previous good sha as chain head, so the import witness of the next
trial still verifies against the retained tar. -/
def ledgerHead (prevSha rejectedSha : Nat) (probeOk : Bool) : Nat :=
  if probeOk then rejectedSha else prevSha

theorem degraded_row_keeps_prev_head (prevSha rejectedSha : Nat) :
    ledgerHead prevSha rejectedSha false = prevSha := by rfl

end MetaCodesControl.ContinuityGate
