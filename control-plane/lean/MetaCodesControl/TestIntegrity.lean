import Std
import MetaCodesControl.CheckGate

/-! # Test integrity obligation: formal policy

The runtime (`src/core/test_integrity.zig`) compares the test suite as it was
when the run started with the workspace at each end-of-turn boundary after
the run used a tool. In enforce mode, ending a turn with tests that existed
before the run rewritten, deleted or disabled earns one message: restore
them, or quote the request that requires the change. The sensor (which
change weakens a test) stays engineering; the POLICY is proven here:

* pristine tests are never nudged;
* observe mode never nudges;
* a nudge needs enforce mode, weakened tests and an unspent budget;
* over ANY trace of boundaries the obligation nudges at most `maxNudges`
  times;
* composed with the host check gate — the integrity step runs first, and a
  nudge continues the run without running the check — the check still runs
  at most once per check-gate continuation of either kind plus once, and the
  run continues at most `budget + maxStopBlocks + maxNudges` times.

Each theorem names the mirroring Zig test. -/

namespace MetaCodesControl.TestIntegrity

/-- Mirrors the Zig `MAX_NUDGES`. -/
def maxNudges : Nat := 1

inductive Mode where
  | enforce
  | observe
  deriving Repr, DecidableEq

inductive Decision where
  | finish
  | recordOnly
  | nudge
  | finishKept
  deriving Repr, DecidableEq

/-- Transcription of `test_integrity.policy`. -/
def policy (mode : Mode) (nudges : Nat) (weakened : Bool) : Decision :=
  match weakened, mode with
  | false, _ => .finish
  | true, .observe => .recordOnly
  | true, .enforce => if nudges < maxNudges then .nudge else .finishKept

/-- Tests that still match the run-start baseline are never nudged.  Zig
mirror: "pristine tests are never nudged". -/
theorem pristine_never_nudged (mode : Mode) (nudges : Nat) :
    policy mode nudges false = .finish := by
  cases mode <;> rfl

/-- Observe mode records and never messages.  Zig mirror: "observe mode
never nudges". -/
theorem observe_never_nudges (nudges : Nat) (weakened : Bool) :
    policy .observe nudges weakened ≠ .nudge := by
  cases weakened <;> simp [policy]

/-- A nudge happens exactly when the mode enforces, the tests are weakened
and the budget is not spent.  Zig mirror: "a nudge needs enforce mode,
weakened tests and budget". -/
theorem nudge_iff (mode : Mode) (nudges : Nat) (weakened : Bool) :
    policy mode nudges weakened = .nudge ↔
      mode = .enforce ∧ nudges < maxNudges ∧ weakened = true := by
  cases weakened with
  | false => cases mode <;> simp [policy]
  | true =>
    cases mode with
    | observe => simp [policy]
    | enforce =>
      by_cases h : nudges < maxNudges
      · simp [policy, h]
      · simp [policy, h]

/-- The end-of-turn boundary of `agent_loop` with both gates: the integrity
step decides first; a nudge continues the run with the acted bit kept for the
next boundary and no check run; otherwise the check gate's boundary
(`CheckGate.boundary`) runs as before. An ended run never moves. -/
structure Composed where
  gate : CheckGate.State
  nudges : Nat
  deriving Repr, DecidableEq

def freshComposed : Composed := { gate := CheckGate.fresh, nudges := 0 }

def boundary (mode : Mode) (gateMode : CheckGate.Mode) (budget : Nat) (s : Composed)
    (acted weakened : Bool) (v : CheckGate.Verdict) (blocked : Bool) : Composed :=
  if s.gate.ended then s
  else if policy mode s.nudges weakened = .nudge then
    { gate := { s.gate with dirty := s.gate.dirty || acted }, nudges := s.nudges + 1 }
  else
    { s with gate := CheckGate.boundary gateMode budget s.gate acted v blocked }

def run (mode : Mode) (gateMode : CheckGate.Mode) (budget : Nat) :
    List (Bool × Bool × CheckGate.Verdict × Bool) → Composed → Composed
  | [], s => s
  | (acted, weakened, v, blocked) :: rest, s =>
    run mode gateMode budget rest (boundary mode gateMode budget s acted weakened v blocked)

def Inv (budget : Nat) (s : Composed) : Prop :=
  CheckGate.Inv budget s.gate ∧ s.nudges ≤ maxNudges

theorem fresh_inv (budget : Nat) : Inv budget freshComposed :=
  ⟨CheckGate.fresh_inv budget, Nat.zero_le _⟩

theorem boundary_inv (mode : Mode) (gateMode : CheckGate.Mode) (budget : Nat) (s : Composed)
    (acted weakened : Bool) (v : CheckGate.Verdict) (blocked : Bool) (h : Inv budget s) :
    Inv budget (boundary mode gateMode budget s acted weakened v blocked) := by
  obtain ⟨hg, hn⟩ := h
  unfold boundary
  split
  · exact ⟨hg, hn⟩
  · split
    · rename_i _ hnudge
      have hlt : s.nudges < maxNudges := ((nudge_iff mode s.nudges weakened).mp hnudge).2.1
      -- Only the dirty bit of the check-gate state moves; its invariant does
      -- not mention it.
      obtain ⟨hc, hs, hlive, hchk⟩ := hg
      exact ⟨⟨hc, hs, hlive, hchk⟩, Nat.succ_le_of_lt hlt⟩
    · exact ⟨CheckGate.boundary_inv gateMode budget s.gate acted v blocked hg, hn⟩

theorem run_inv (mode : Mode) (gateMode : CheckGate.Mode) (budget : Nat)
    (trace : List (Bool × Bool × CheckGate.Verdict × Bool)) (s : Composed) (h : Inv budget s) :
    Inv budget (run mode gateMode budget trace s) := by
  induction trace generalizing s with
  | nil => exact h
  | cons head rest ih =>
    obtain ⟨acted, weakened, v, blocked⟩ := head
    exact ih _ (boundary_inv mode gateMode budget s acted weakened v blocked h)

/-- Over any trace of boundaries a fresh run is nudged at most `maxNudges`
times, whatever the check gate does.  Zig mirror: "a nudge needs enforce
mode, weakened tests and budget". -/
theorem nudges_bounded (mode : Mode) (gateMode : CheckGate.Mode) (budget : Nat)
    (trace : List (Bool × Bool × CheckGate.Verdict × Bool)) :
    (run mode gateMode budget trace freshComposed).nudges ≤ maxNudges :=
  (run_inv mode gateMode budget trace freshComposed (fresh_inv budget)).2

/-- The integrity step never adds a check: over any trace the check still
runs at most `budget + maxStopBlocks + 1` times.  Zig mirror (L2): "weakened
tests are messaged before the check runs, and the check then judges the
restored tests". -/
theorem composed_checks_bounded (mode : Mode) (gateMode : CheckGate.Mode) (budget : Nat)
    (trace : List (Bool × Bool × CheckGate.Verdict × Bool)) :
    (run mode gateMode budget trace freshComposed).gate.checks ≤
      budget + CheckGate.maxStopBlocks + 1 := by
  obtain ⟨⟨hc, hs, _, hchk⟩, _⟩ := run_inv mode gateMode budget trace freshComposed (fresh_inv budget)
  exact Nat.le_trans hchk (Nat.succ_le_succ (Nat.add_le_add hc hs))

/-- Every way the end-of-turn boundary can send the run back — a check
continuation, a Stop-hook block, an integrity message — is bounded, so the
run continues at most `budget + maxStopBlocks + maxNudges` times. -/
theorem composed_continuations_bounded (mode : Mode) (gateMode : CheckGate.Mode) (budget : Nat)
    (trace : List (Bool × Bool × CheckGate.Verdict × Bool)) :
    let s := run mode gateMode budget trace freshComposed
    s.gate.continuations + s.gate.stopBlocks + s.nudges ≤
      budget + CheckGate.maxStopBlocks + maxNudges := by
  obtain ⟨⟨hc, hs, _, _⟩, hn⟩ := run_inv mode gateMode budget trace freshComposed (fresh_inv budget)
  exact Nat.add_le_add (Nat.add_le_add hc hs) hn

end MetaCodesControl.TestIntegrity
