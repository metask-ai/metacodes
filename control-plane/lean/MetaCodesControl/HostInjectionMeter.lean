import Std

/-! # Host injection meter: the composition meta-rule

Every process gate (requirement ledger, task obligations, any future gate)
proves its own nudge budget, but per-gate bounds do not compose: adding
individually-bounded mechanisms one at a time silently accumulates host
interventions. The runtime (`src/core/host_injection_meter.zig`) routes
every host injection through one meter, so the bound below quantifies over
ARBITRARY gate request sequences — it is a theorem about the rule system,
not about any one rule.

Each theorem names the mirroring Zig test. -/

namespace MetaCodesControl.HostInjectionMeter

def cap : Nat := 7

/-- One meter step: a gate asks for an injection; the request is granted
iff budget remains. Returns (granted?, next used). -/
def step (used : Nat) : Bool × Nat :=
  if used ≥ cap then (false, used) else (true, used + 1)

/-- Fold an arbitrary request count (each request may come from any gate,
in any interleaving — the meter cannot tell and must not care), returning
(granted total, used). The request abstraction is what makes the bound
meta: it quantifies over every gate implementation and ordering. -/
def run : Nat → Nat × Nat
  | 0 => (0, 0)
  | n + 1 =>
    let prev := run n
    let s := step prev.2
    (prev.1 + (if s.1 then 1 else 0), s.2)

/-- The meter state never exceeds the cap. -/
theorem used_le_cap (requests : Nat) : (run requests).2 ≤ cap := by
  induction requests with
  | zero => simp [run]
  | succ n ih =>
    by_cases h : (run n).2 ≥ cap
    · simp [run, step, h]
      omega
    · simp [run, step, h]
      omega

/-- Every granted injection is accounted: grants equal meter usage. -/
theorem granted_eq_used (requests : Nat) :
    (run requests).1 = (run requests).2 := by
  induction requests with
  | zero => simp [run]
  | succ n ih =>
    by_cases h : (run n).2 ≥ cap
    · simp [run, step, h, ih]
    · simp [run, step, h, ih]

/-- The meta-bound: however many requests arrive, from however many gates,
in whatever order, at most `cap` host injections are granted per run.
Zig mirrors: "meter never exceeds the cap regardless of request count" and
"meter is gate-agnostic: interleaved consumers share one bound". -/
theorem consumed_never_exceeds_cap (requests : Nat) :
    (run requests).1 ≤ cap := by
  rw [granted_eq_used]
  exact used_le_cap requests

end MetaCodesControl.HostInjectionMeter
