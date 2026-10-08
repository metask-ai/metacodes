import Std

/-! # Host check gate: formal policy

The runtime (`src/core/check_gate.zig`) runs the check command pinned at
startup (`--host-check`) when the model ends its turn after a
delivery-capable action, and — in enforce mode — continues the same
conversation with the host's verdict when the check fails cleanly, within a
fixed budget. A blocking Stop hook (`decision: "block"`) continues the run
the same way under its own bound. The sensors (what counts as a
delivery-capable action, how check output becomes a verdict, what counts as
tampering with the check) stay engineering; the POLICY is proven here:

* clean boundaries are never checked — without a delivery-capable action
  since the last check the host runs nothing and the run ends;
* only a clean failure continues — a pass, a tampered verdict or a missing
  verdict always ends the run;
* observe mode never continues — the control arm records the same verdicts
  and leaves the conversation untouched;
* a continuation needs budget, and over ANY trace of turn boundaries the
  number of check continuations never exceeds the budget;
* a Stop hook continues the run only when it blocks and its own budget is
  not spent (it is consulted whenever the check does not continue the run),
  so over any trace it continues at most `maxStopBlocks` times;
* the check runs at most once per continuation of either kind plus once,
  so never more than budget + `maxStopBlocks` + 1 times per run.

Each theorem names the mirroring Zig test. -/

namespace MetaCodesControl.CheckGate

/-- Mirrors the Zig `MAX_STOP_HOOK_BLOCKS`. -/
def maxStopBlocks : Nat := 5

inductive Mode where
  | enforce
  | observe
  deriving Repr, DecidableEq

inductive Verdict where
  | passed
  | failed
  | tainted
  | unavailable
  deriving Repr, DecidableEq

inductive Decision where
  | finishPassed
  | finishTainted
  | finishUnavailable
  | finishExhausted
  | recordOnly
  | continueRun
  deriving Repr, DecidableEq

structure State where
  /-- A delivery-capable action happened since the last check. -/
  dirty : Bool
  /-- The run reached a terminal boundary decision. -/
  ended : Bool
  checks : Nat
  continuations : Nat
  stopBlocks : Nat
  deriving Repr, DecidableEq

def fresh : State :=
  { dirty := false, ended := false, checks := 0, continuations := 0, stopBlocks := 0 }

/-- Transcription of `State.shouldCheck`. -/
def shouldCheck (s : State) : Bool := s.dirty

/-- Transcription of `check_gate.decide`. -/
def decide (mode : Mode) (budget : Nat) (s : State) (v : Verdict) : Decision :=
  match v with
  | .passed => .finishPassed
  | .tainted => .finishTainted
  | .unavailable => .finishUnavailable
  | .failed =>
    match mode with
    | .observe => .recordOnly
    | .enforce => if s.continuations < budget then .continueRun else .finishExhausted

/-- Transcription of `check_gate.stopContinues`. -/
def stopContinues (blocked : Bool) (used : Nat) : Bool :=
  blocked && Decidable.decide (used < maxStopBlocks)

/-- A boundary with no delivery-capable action since the last check is never
checked.  Zig mirror: "clean boundary is never checked". -/
theorem clean_boundary_never_checked (s : State) (h : s.dirty = false) :
    shouldCheck s = false := by
  unfold shouldCheck
  exact h

/-- Only a clean failure can continue the run.  Zig mirror: "only a clean
failure continues". -/
theorem only_failure_continues (mode : Mode) (budget : Nat) (s : State) (v : Verdict)
    (h : decide mode budget s v = .continueRun) : v = .failed := by
  cases v with
  | passed => simp [decide] at h
  | failed => rfl
  | tainted => simp [decide] at h
  | unavailable => simp [decide] at h

/-- Observe mode never continues: the control arm only records.  Zig mirror:
"observe mode never continues". -/
theorem observe_never_continues (budget : Nat) (s : State) (v : Verdict) :
    decide .observe budget s v ≠ .continueRun := by
  cases v <;> simp [decide]

/-- A continuation is decided only below the budget.  Zig mirror:
"continuation needs budget". -/
theorem continue_needs_budget (mode : Mode) (budget : Nat) (s : State) (v : Verdict)
    (h : decide mode budget s v = .continueRun) : s.continuations < budget := by
  cases v with
  | passed => simp [decide] at h
  | tainted => simp [decide] at h
  | unavailable => simp [decide] at h
  | failed =>
    cases mode with
    | observe => simp [decide] at h
    | enforce =>
      unfold decide at h
      by_cases hb : s.continuations < budget
      · exact hb
      · simp [hb] at h

/-- A Stop hook that does not block never continues the run.  Zig mirror:
"a non-blocking Stop hook never continues". -/
theorem unblocked_never_continues (used : Nat) : stopContinues false used = false := by
  simp [stopContinues]

/-- A Stop-hook continuation is decided only below its own budget. -/
theorem stop_continue_needs_budget (blocked : Bool) (used : Nat)
    (h : stopContinues blocked used = true) : used < maxStopBlocks := by
  unfold stopContinues at h
  cases blocked with
  | false => simp at h
  | true =>
    by_cases hu : used < maxStopBlocks
    · exact hu
    · simp only [decide_eq_false hu, Bool.and_false, Bool.false_eq_true] at h

/-- Line-for-line transcription of the end-of-turn boundary in `agent_loop`:
the sensor marks the state dirty when the turn had a delivery-capable action;
a dirty boundary runs the check and applies the decision (a continuation
consumes the check budget). Whenever the check does not continue the run —
or no check ran — the Stop hook decides: a block within its own budget
continues the run, anything else ends it. An ended run never moves. -/
def boundary (mode : Mode) (budget : Nat) (s : State) (acted : Bool) (v : Verdict)
    (blocked : Bool) : State :=
  if s.ended then s
  else if s.dirty || acted then
    if decide mode budget { s with dirty := true } v = .continueRun then
      { s with dirty := false, checks := s.checks + 1, continuations := s.continuations + 1 }
    else if stopContinues blocked s.stopBlocks then
      { s with dirty := false, checks := s.checks + 1, stopBlocks := s.stopBlocks + 1 }
    else
      { s with dirty := false, ended := true, checks := s.checks + 1 }
  else if stopContinues blocked s.stopBlocks then
    { s with stopBlocks := s.stopBlocks + 1 }
  else
    { s with ended := true }

def run (mode : Mode) (budget : Nat) : List (Bool × Verdict × Bool) → State → State
  | [], s => s
  | (acted, v, blocked) :: rest, s => run mode budget rest (boundary mode budget s acted v blocked)

/-- The trace invariant: both budgets hold; a live run has checked at most
once per continuation of either kind, an ended run at most once more. -/
def Inv (budget : Nat) (s : State) : Prop :=
  s.continuations ≤ budget ∧ s.stopBlocks ≤ maxStopBlocks ∧
    (s.ended = false → s.checks ≤ s.continuations + s.stopBlocks) ∧
    s.checks ≤ s.continuations + s.stopBlocks + 1

theorem fresh_inv (budget : Nat) : Inv budget fresh := by
  simp [Inv, fresh]

theorem boundary_inv (mode : Mode) (budget : Nat) (s : State) (acted : Bool) (v : Verdict)
    (blocked : Bool) (h : Inv budget s) : Inv budget (boundary mode budget s acted v blocked) := by
  obtain ⟨hc, hs, hlive, hchk⟩ := h
  unfold boundary
  split
  · exact ⟨hc, hs, hlive, hchk⟩
  · rename_i he
    have he' : s.ended = false := by simpa using he
    have hl : s.checks ≤ s.continuations + s.stopBlocks := hlive he'
    split
    · split
      · -- the check failed cleanly and continues the run
        rename_i hd
        have hlt : s.continuations < budget :=
          continue_needs_budget mode budget { s with dirty := true } v hd
        refine ⟨Nat.succ_le_of_lt hlt, hs, ?_, ?_⟩
        · intro _
          show s.checks + 1 ≤ s.continuations + 1 + s.stopBlocks
          rw [Nat.add_right_comm]
          exact Nat.succ_le_succ hl
        · show s.checks + 1 ≤ s.continuations + 1 + s.stopBlocks + 1
          rw [Nat.add_right_comm s.continuations 1 s.stopBlocks]
          exact Nat.le_succ_of_le (Nat.succ_le_succ hl)
      · split
        · -- the check ended its part; a blocking Stop hook continues
          rename_i _ hstop
          have hsl : s.stopBlocks < maxStopBlocks := stop_continue_needs_budget blocked _ hstop
          refine ⟨hc, Nat.succ_le_of_lt hsl, ?_, ?_⟩
          · intro _
            show s.checks + 1 ≤ s.continuations + (s.stopBlocks + 1)
            exact Nat.succ_le_succ hl
          · show s.checks + 1 ≤ s.continuations + (s.stopBlocks + 1) + 1
            exact Nat.le_succ_of_le (Nat.succ_le_succ hl)
        · -- terminal
          refine ⟨hc, hs, ?_, ?_⟩
          · intro hf
            simp at hf
          · show s.checks + 1 ≤ s.continuations + s.stopBlocks + 1
            exact Nat.succ_le_succ hl
    · split
      · -- clean boundary, blocking Stop hook continues
        rename_i _ hstop
        have hsl : s.stopBlocks < maxStopBlocks := stop_continue_needs_budget blocked _ hstop
        refine ⟨hc, Nat.succ_le_of_lt hsl, ?_, ?_⟩
        · intro _
          show s.checks ≤ s.continuations + (s.stopBlocks + 1)
          exact Nat.le_succ_of_le hl
        · show s.checks ≤ s.continuations + (s.stopBlocks + 1) + 1
          exact Nat.le_succ_of_le (Nat.le_succ_of_le hl)
      · -- clean boundary, terminal
        refine ⟨hc, hs, ?_, ?_⟩
        · intro hf
          simp at hf
        · show s.checks ≤ s.continuations + s.stopBlocks + 1
          exact Nat.le_succ_of_le hl

theorem run_inv (mode : Mode) (budget : Nat) (trace : List (Bool × Verdict × Bool)) (s : State)
    (h : Inv budget s) : Inv budget (run mode budget trace s) := by
  induction trace generalizing s with
  | nil => exact h
  | cons head rest ih =>
    obtain ⟨acted, v, blocked⟩ := head
    exact ih _ (boundary_inv mode budget s acted v blocked h)

/-- Bounded actuation over ANY trace of boundaries: a fresh run never
continues on a check verdict more often than the budget allows.  Zig mirror:
"continuations and checks stay within budget over a trace". -/
theorem continuations_bounded (mode : Mode) (budget : Nat)
    (trace : List (Bool × Verdict × Bool)) :
    (run mode budget trace fresh).continuations ≤ budget :=
  (run_inv mode budget trace fresh (fresh_inv budget)).1

/-- Over any trace the Stop hook continues a fresh run at most
`maxStopBlocks` times.  Zig mirror: "Stop hook blocks stay within budget". -/
theorem stop_blocks_bounded (mode : Mode) (budget : Nat)
    (trace : List (Bool × Verdict × Bool)) :
    (run mode budget trace fresh).stopBlocks ≤ maxStopBlocks :=
  (run_inv mode budget trace fresh (fresh_inv budget)).2.1

/-- Over any trace a fresh run runs the check at most once per continuation
of either kind plus once: never more than budget + maxStopBlocks + 1 times.
Zig mirror: "continuations and checks stay within budget over a trace". -/
theorem checks_bounded (mode : Mode) (budget : Nat) (trace : List (Bool × Verdict × Bool)) :
    (run mode budget trace fresh).checks ≤ budget + maxStopBlocks + 1 := by
  obtain ⟨hc, hs, _, hchk⟩ := run_inv mode budget trace fresh (fresh_inv budget)
  exact Nat.le_trans hchk (Nat.succ_le_succ (Nat.add_le_add hc hs))

end MetaCodesControl.CheckGate
