import Std

/-! # Stall gate: formal policy

The runtime (`src/core/stall_gate.zig`) watches every executed tool round.
Each slot that ran yields a call key and, unless it failed, an evidence key.
A round is *progress* when some evidence key is not in the gate's memory,
*stale* when something ran but nothing is new, and *neutral* when nothing ran.
A long enough stale stretch ends the run with `StopReason.stalled`.

The hashing, the host-timing normalization and the anchoring of keys to
conversation blocks are sensor engineering. This file transcribes the round
scan, the bounded call window and the policy, and models every way the Zig
memory forgets as an adversarial `forget` event. Those ways are capacity
eviction, results leaving the model's view, and keys with no block. Forgetting
only makes keys look new, so the theorems hold for every forgetting pattern:

* bounded actuation — over any trace of rounds and forgets the decision
  count never exceeds `maxDecisions` (enforce mode stops at the first);
* progress never fires — a round with a key the memory does not hold is never
  followed by a decision, for every threshold setting;
* new rounds never fire — if every round carries a key that occurs in no
  earlier round, there is no decision at all, because memory ⊆ history;
* the positive side — from a fresh budget, enough consecutive stale rounds
  always produce exactly one decision.

Each theorem names the mirroring Zig test. -/

namespace MetaCodesControl.StallGate

/-- Mirrors the Zig `MAX_STALL_DECISIONS` (lockstep-checked by
`scripts/eval/tests/test_delivery_cadence_constants.py`). -/
def maxDecisions : Nat := 1

/-- Mirrors the Zig `STRETCH_CAPACITY`: the call window of a stale stretch. -/
def stretchCap : Nat := 32

/-- Mirror the Zig `DEFAULT_REPEAT_ROUNDS`, `DEFAULT_REPEAT_CALLS` and
`DEFAULT_STALE_ROUNDS`. The theorems hold for every threshold; these are the
shipped ones. -/
def defaultRepeatRounds : Nat := 4
def defaultRepeatCalls : Nat := 4
def defaultStaleRounds : Nat := 8

structure Thresholds where
  repeatRounds : Nat
  repeatCalls : Nat
  staleRounds : Nat
  deriving Repr, DecidableEq

def defaultThresholds : Thresholds :=
  { repeatRounds := defaultRepeatRounds, repeatCalls := defaultRepeatCalls,
    staleRounds := defaultStaleRounds }

/-- One slot that ran (Zig `Reading`): its call key and, unless it failed,
its evidence key. Slots that never ran are not given to the gate. -/
structure Slot where
  call : Nat
  evidence : Option Nat
  deriving Repr, DecidableEq

inductive Cause where
  | repeating
  | stale
  deriving Repr, DecidableEq

structure State where
  seen : List Nat
  stretch : List Nat
  staleRounds : Nat
  decisions : Nat
  deriving Repr

def fresh : State := { seen := [], stretch := [], staleRounds := 0, decisions := 0 }

/-- Membership test of the memory, by `Nat` equality alone (`List.elem`
would route through a `LawfulBEq` instance that costs an extra axiom). -/
def remembered (k : Nat) : List Nat → Bool
  | [] => false
  | a :: l => if k = a then true else remembered k l

theorem mem_of_remembered (k : Nat) : ∀ l : List Nat, remembered k l = true → k ∈ l
  | [], h => absurd h Bool.false_ne_true
  | a :: l, h => by
    unfold remembered at h
    by_cases hka : k = a
    · rw [hka]
      exact List.mem_cons_self _ _
    · rw [if_neg hka] at h
      exact List.mem_cons_of_mem _ (mem_of_remembered k l h)

theorem remembered_of_mem (k : Nat) : ∀ l : List Nat, k ∈ l → remembered k l = true
  | [], h => absurd h (List.not_mem_nil _)
  | a :: l, h => by
    unfold remembered
    by_cases hka : k = a
    · rw [if_pos hka]
    · rw [if_neg hka]
      rcases List.mem_cons.mp h with h1 | h1
      · exact absurd h1 hka
      · exact remembered_of_mem k l h1

structure Scan where
  seen : List Nat
  stretch : List Nat
  novel : Bool

/-- Transcription of `State.scanOne`: the call enters the window (oldest
dropped first); a new evidence key is admitted and marks the round novel.
Membership is `remembered` (`mem_of_remembered`/`remembered_of_mem` relate it
to `∈`), which keeps the model within the `propext` axiom budget. -/
def scanSlot (sc : Scan) (sl : Slot) : Scan :=
  match sl.evidence with
  | none => { sc with stretch := (sl.call :: sc.stretch).take stretchCap }
  | some k =>
    if remembered k sc.seen then { sc with stretch := (sl.call :: sc.stretch).take stretchCap }
    else { seen := k :: sc.seen, stretch := (sl.call :: sc.stretch).take stretchCap, novel := true }

def scanRound (s : State) (round : List Slot) : Scan :=
  round.foldl scanSlot { seen := s.seen, stretch := s.stretch, novel := false }

/-- Transcription of `State.observeSlots`/`closeRound`: progress resets the
stretch, stale lengthens it, a neutral round (nothing ran) changes nothing. -/
def observe (s : State) : List Slot → State
  | [] => s
  | sl :: rest =>
    let sc := scanRound s (sl :: rest)
    if sc.novel then { s with seen := sc.seen, stretch := [], staleRounds := 0 }
    else { s with seen := sc.seen, stretch := sc.stretch, staleRounds := s.staleRounds + 1 }

/-- The most frequent call in the window and how often it occurs. -/
def maxRepeat (l : List Nat) : Nat := (l.map (fun k => l.count k)).foldl max 0

/-- Transcription of `State.decide`. The `staleRounds = 0` guard makes
"progress never fires" hold for every threshold setting. -/
def decide (t : Thresholds) (s : State) : Option Cause :=
  if maxDecisions ≤ s.decisions then none
  else if s.staleRounds = 0 then none
  else if t.repeatRounds ≤ s.staleRounds ∧ t.repeatCalls ≤ maxRepeat s.stretch then some .repeating
  else if t.staleRounds ≤ s.staleRounds then some .stale
  else none

/-- Transcription of `State.noteDecided`: a decision is counted. -/
def step (t : Thresholds) (s : State) : State :=
  match decide t s with
  | some _ => { s with decisions := s.decisions + 1 }
  | none => s

/-- A round, or the memory forgetting the keys `drop` selects. -/
inductive Event where
  | round (slots : List Slot)
  | forget (drop : Nat → Bool)

def forget (s : State) (drop : Nat → Bool) : State :=
  { s with seen := s.seen.filter (fun k => !drop k) }

def apply (t : Thresholds) (s : State) : Event → State
  | .round r => step t (observe s r)
  | .forget d => forget s d

def run (t : Thresholds) : List Event → State → State
  | [], s => s
  | e :: rest, s => run t rest (apply t s e)

/-! ## Policy -/

/-- Progress never fires, for every threshold setting. Zig mirror: "policy:
zero stale rounds never fires for any thresholds". -/
theorem progress_never_fires (t : Thresholds) (s : State) (h : s.staleRounds = 0) :
    decide t s = none := by
  unfold decide
  simp [h]

/-- Any positive decision comes from a count strictly below the budget. -/
theorem decision_needs_budget (t : Thresholds) (s : State) (c : Cause)
    (h : decide t s = some c) : s.decisions < maxDecisions := by
  unfold decide at h
  by_cases hb : maxDecisions ≤ s.decisions
  · simp [hb] at h
  · exact Nat.lt_of_not_le hb

/-- Below both tiers nothing fires. Zig mirror: "each tier needs its own
condition". -/
theorem below_thresholds_never_fire (t : Thresholds) (s : State)
    (hs : s.staleRounds < t.staleRounds)
    (hr : s.staleRounds < t.repeatRounds ∨ maxRepeat s.stretch < t.repeatCalls) :
    decide t s = none := by
  unfold decide
  split
  · rfl
  · split
    · rfl
    · split
      · rename_i h
        rcases hr with hr | hr
        · exact absurd h.1 (Nat.not_le_of_lt hr)
        · exact absurd h.2 (Nat.not_le_of_lt hr)
      · split
        · rename_i h
          exact absurd h (Nat.not_le_of_lt hs)
        · rfl

/-- Long enough stale stretches always fire while the budget lasts. -/
theorem stale_threshold_fires (t : Thresholds) (s : State)
    (hb : s.decisions < maxDecisions) (hpos : 0 < s.staleRounds)
    (hs : t.staleRounds ≤ s.staleRounds) : decide t s ≠ none := by
  unfold decide
  rw [if_neg (Nat.not_le_of_lt hb), if_neg (Nat.pos_iff_ne_zero.mp hpos)]
  by_cases hr : t.repeatRounds ≤ s.staleRounds ∧ t.repeatCalls ≤ maxRepeat s.stretch
  · rw [if_pos hr]
    exact fun h => Option.noConfusion h
  · rw [if_neg hr, if_pos hs]
    exact fun h => Option.noConfusion h

/-! ## Bounded actuation -/

theorem step_decisions_le (t : Thresholds) (s : State) (h : s.decisions ≤ maxDecisions) :
    (step t s).decisions ≤ maxDecisions := by
  unfold step
  split
  · rename_i c hc
    exact decision_needs_budget t s c hc
  · exact h

theorem step_decisions_ge (t : Thresholds) (s : State) : s.decisions ≤ (step t s).decisions := by
  unfold step
  split
  · simp
  · exact Nat.le_refl _

/-- The sensor never touches the decision count. -/
theorem observe_decisions (s : State) (r : List Slot) : (observe s r).decisions = s.decisions := by
  cases r with
  | nil => rfl
  | cons sl rest =>
    simp only [observe]
    split <;> rfl

theorem apply_decisions_le (t : Thresholds) (s : State) (e : Event)
    (h : s.decisions ≤ maxDecisions) : (apply t s e).decisions ≤ maxDecisions := by
  cases e with
  | round r =>
    apply step_decisions_le
    rw [observe_decisions]
    exact h
  | forget d => exact h

theorem apply_decisions_ge (t : Thresholds) (s : State) (e : Event) :
    s.decisions ≤ (apply t s e).decisions := by
  cases e with
  | round r =>
    have := step_decisions_ge t (observe s r)
    rw [observe_decisions] at this
    exact this
  | forget d => exact Nat.le_refl _

/-- Bounded actuation over ANY trace of rounds and forgets. Zig mirror:
"repeating trace ... fires the repeat tier exactly once". -/
theorem decisions_bounded (t : Thresholds) (trace : List Event) (s : State)
    (h : s.decisions ≤ maxDecisions) : (run t trace s).decisions ≤ maxDecisions := by
  induction trace generalizing s with
  | nil => exact h
  | cons e rest ih => exact ih _ (apply_decisions_le t s e h)

theorem decisions_monotone (t : Thresholds) (trace : List Event) (s : State) :
    s.decisions ≤ (run t trace s).decisions := by
  induction trace generalizing s with
  | nil => exact Nat.le_refl _
  | cons e rest ih => exact Nat.le_trans (apply_decisions_ge t s e) (ih _)

/-- A fresh gate starts with no decisions, so every real run is within budget. -/
theorem fresh_run_bounded (t : Thresholds) (trace : List Event) :
    (run t trace fresh).decisions ≤ maxDecisions :=
  decisions_bounded t trace fresh (Nat.zero_le _)

/-! ## The round scan -/

theorem scanSlot_novel_mono (sc : Scan) (sl : Slot) (h : sc.novel = true) :
    (scanSlot sc sl).novel = true := by
  unfold scanSlot
  split
  · exact h
  · split
    · exact h
    · rfl

theorem foldl_novel_mono (l : List Slot) (sc : Scan) (h : sc.novel = true) :
    (l.foldl scanSlot sc).novel = true := by
  induction l generalizing sc with
  | nil => exact h
  | cons sl rest ih => exact ih _ (scanSlot_novel_mono sc sl h)

/-- A slot's evidence is either already remembered after it, or it marked the
round novel. -/
theorem scanSlot_key_seen_or_novel (sc : Scan) (sl : Slot) (k : Nat)
    (hk : sl.evidence = some k) : k ∈ (scanSlot sc sl).seen ∨ (scanSlot sc sl).novel = true := by
  unfold scanSlot
  rw [hk]
  simp only
  split
  · rename_i hmem
    exact Or.inl (mem_of_remembered _ _ hmem)
  · exact Or.inr rfl

/-- Remembered keys stay remembered within a round. -/
theorem scanSlot_seen_mono (sc : Scan) (sl : Slot) (x : Nat) (hx : x ∈ sc.seen) :
    x ∈ (scanSlot sc sl).seen := by
  unfold scanSlot
  split
  · exact hx
  · split
    · exact hx
    · exact List.mem_cons_of_mem _ hx

/-- A slot that did not mark the round novel admitted nothing. -/
theorem scanSlot_seen_of_not_novel (sc : Scan) (sl : Slot) (h : ¬(scanSlot sc sl).novel = true) :
    (scanSlot sc sl).seen = sc.seen := by
  revert h
  unfold scanSlot
  cases sl.evidence with
  | none => intro _; rfl
  | some k =>
    dsimp only
    cases remembered k sc.seen with
    | true => intro _; rfl
    | false => intro h; exact absurd rfl h

/-- A round with a key the memory does not hold is novel. -/
theorem foldl_novel_of_new (l : List Slot) (sc : Scan)
    (h : ∃ sl ∈ l, ∃ k, sl.evidence = some k ∧ k ∉ sc.seen) :
    (l.foldl scanSlot sc).novel = true := by
  induction l generalizing sc with
  | nil =>
    obtain ⟨sl, hmem, _⟩ := h
    exact absurd hmem (List.not_mem_nil _)
  | cons hd rest ih =>
    show (rest.foldl scanSlot (scanSlot sc hd)).novel = true
    obtain ⟨sl, hmem, k, hk, hnot⟩ := h
    rcases List.mem_cons.mp hmem with heq | hrest
    · -- the witness is this slot: it is admitted now, so the round is novel
      subst heq
      have hnov : (scanSlot sc sl).novel = true := by
        unfold scanSlot
        rw [hk]
        dsimp only
        rw [if_neg (fun hin => hnot (mem_of_remembered _ _ hin))]
      exact foldl_novel_mono rest _ hnov
    · by_cases hn : (scanSlot sc hd).novel = true
      · exact foldl_novel_mono rest _ hn
      · -- `hd` admitted nothing, so `k` is still missing from the memory
        apply ih
        refine ⟨sl, hrest, k, hk, ?_⟩
        rw [scanSlot_seen_of_not_novel sc hd hn]
        exact hnot

/-- Evidence keys of a round. -/
def evKeys : List Slot → List Nat
  | [] => []
  | sl :: rest =>
    match sl.evidence with
    | some k => k :: evKeys rest
    | none => evKeys rest

theorem mem_evKeys_head (sl : Slot) (rest : List Slot) (k : Nat) (hk : sl.evidence = some k) :
    k ∈ evKeys (sl :: rest) := by
  unfold evKeys
  rw [hk]
  exact List.mem_cons_self _ _

theorem mem_evKeys_tail (sl : Slot) (rest : List Slot) (x : Nat) (hx : x ∈ evKeys rest) :
    x ∈ evKeys (sl :: rest) := by
  unfold evKeys
  split
  · exact List.mem_cons_of_mem _ hx
  · exact hx

/-- After a round, the memory holds only what it held plus the round's keys. -/
theorem foldl_seen_sub (l : List Slot) (sc : Scan) (x : Nat)
    (hx : x ∈ (l.foldl scanSlot sc).seen) : x ∈ sc.seen ∨ x ∈ evKeys l := by
  induction l generalizing sc with
  | nil => exact Or.inl hx
  | cons hd rest ih =>
    simp only [List.foldl_cons] at hx
    rcases ih _ hx with h1 | h2
    · unfold scanSlot at h1
      split at h1
      · exact Or.inl h1
      · rename_i k hk
        split at h1
        · exact Or.inl h1
        · rcases List.mem_cons.mp h1 with heq | hold
          · subst heq
            exact Or.inr (mem_evKeys_head hd rest _ hk)
          · exact Or.inl hold
    · exact Or.inr (mem_evKeys_tail hd rest x h2)

/-- A round whose keys are all remembered leaves the memory and the novelty
flag as they were. -/
theorem foldl_stale (l : List Slot) (sc : Scan)
    (h : ∀ sl ∈ l, ∀ k, sl.evidence = some k → k ∈ sc.seen) :
    (l.foldl scanSlot sc).seen = sc.seen ∧ (l.foldl scanSlot sc).novel = sc.novel := by
  induction l generalizing sc with
  | nil => exact ⟨rfl, rfl⟩
  | cons hd rest ih =>
    show (rest.foldl scanSlot (scanSlot sc hd)).seen = sc.seen ∧
      (rest.foldl scanSlot (scanSlot sc hd)).novel = sc.novel
    have hstep : (scanSlot sc hd).seen = sc.seen ∧ (scanSlot sc hd).novel = sc.novel := by
      unfold scanSlot
      cases hev : hd.evidence with
      | none => exact ⟨rfl, rfl⟩
      | some k =>
        have hin : remembered k sc.seen = true :=
          remembered_of_mem _ _ (h hd (List.mem_cons_self _ _) k hev)
        dsimp only
        rw [if_pos hin]
        exact ⟨rfl, rfl⟩
    have hrest : ∀ sl ∈ rest, ∀ k, sl.evidence = some k → k ∈ (scanSlot sc hd).seen := by
      intro sl hsl k hk
      rw [hstep.1]
      exact h sl (List.mem_cons_of_mem _ hsl) k hk
    obtain ⟨h1, h2⟩ := ih _ hrest
    exact ⟨h1.trans hstep.1, h2.trans hstep.2⟩

/-! ## Progress never fires -/

/-- A round with a new key resets the stale stretch. -/
theorem observe_new_resets (s : State) (r : List Slot)
    (h : ∃ sl ∈ r, ∃ k, sl.evidence = some k ∧ k ∉ s.seen) :
    (observe s r).staleRounds = 0 := by
  cases r with
  | nil =>
    obtain ⟨sl, hmem, _⟩ := h
    exact absurd hmem (List.not_mem_nil _)
  | cons hd rest =>
    have hnov : (scanRound s (hd :: rest)).novel = true :=
      foldl_novel_of_new (hd :: rest) _ h
    unfold observe
    dsimp only
    rw [if_pos hnov]

/-- The boundary after a round with a new key never decides. Zig mirror:
"progressing trace: a round with one new result never fires". -/
theorem new_round_no_decision (t : Thresholds) (s : State) (r : List Slot)
    (h : ∃ sl ∈ r, ∃ k, sl.evidence = some k ∧ k ∉ s.seen) :
    step t (observe s r) = observe s r := by
  unfold step
  rw [progress_never_fires t _ (observe_new_resets s r h)]

/-- Every round carries a key the gate's memory does not hold at that point. -/
def FreshTrace (t : Thresholds) : State → List Event → Prop
  | _, [] => True
  | s, .forget d :: rest => FreshTrace t (forget s d) rest
  | s, .round r :: rest =>
    (∃ sl ∈ r, ∃ k, sl.evidence = some k ∧ k ∉ s.seen) ∧ FreshTrace t (apply t s (.round r)) rest

/-- No decision when every round yields a key the memory does not hold,
whatever forgetting happens in between. Zig mirror: "progressing trace". -/
theorem fresh_rounds_never_fire (t : Thresholds) (trace : List Event) (s : State)
    (h : FreshTrace t s trace) : (run t trace s).decisions = s.decisions := by
  induction trace generalizing s with
  | nil => rfl
  | cons e rest ih =>
    cases e with
    | round r =>
      obtain ⟨hnew, hrest⟩ := h
      simp only [run]
      rw [ih _ hrest]
      simp only [apply]
      rw [new_round_no_decision t s r hnew, observe_decisions]
    | forget d =>
      simp only [run]
      exact ih _ h

/-- Every round carries a key that occurs in no earlier round (nor in `h`). -/
def NewRounds : List Nat → List Event → Prop
  | _, [] => True
  | h, .forget _ :: rest => NewRounds h rest
  | h, .round r :: rest => (∃ sl ∈ r, ∃ k, sl.evidence = some k ∧ k ∉ h) ∧ NewRounds (evKeys r ++ h) rest

theorem observe_seen_sub (s : State) (r : List Slot) (x : Nat) (hx : x ∈ (observe s r).seen) :
    x ∈ s.seen ∨ x ∈ evKeys r := by
  cases r with
  | nil => exact Or.inl hx
  | cons hd rest =>
    simp only [observe] at hx
    split at hx <;> exact foldl_seen_sub _ _ x hx

/-- No decision when every round yields a key never seen before in the run,
because the memory only ever holds keys from earlier rounds, however it
forgets. Zig mirror: "progressing trace: TDD ... never fire". -/
theorem new_rounds_never_fire (t : Thresholds) (trace : List Event) (s : State) (h : List Nat)
    (hsub : ∀ k ∈ s.seen, k ∈ h) (hnew : NewRounds h trace) :
    (run t trace s).decisions = s.decisions := by
  induction trace generalizing s h with
  | nil => rfl
  | cons e rest ih =>
    cases e with
    | round r =>
      obtain ⟨⟨sl, hsl, k, hk, hkh⟩, hrest⟩ := hnew
      have hfresh : ∃ sl ∈ r, ∃ k, sl.evidence = some k ∧ k ∉ s.seen :=
        ⟨sl, hsl, k, hk, fun hin => hkh (hsub k hin)⟩
      simp only [run, apply]
      rw [new_round_no_decision t s r hfresh]
      rw [ih (observe s r) (evKeys r ++ h) ?_ hrest, observe_decisions]
      intro x hx
      rcases observe_seen_sub s r x hx with h1 | h2
      · exact List.mem_append.mpr (Or.inr (hsub x h1))
      · exact List.mem_append.mpr (Or.inl h2)
    | forget d =>
      simp only [run, apply]
      refine ih _ h ?_ hnew
      intro x hx
      simp only [forget, List.mem_filter] at hx
      exact hsub x hx.1

/-- From a fresh gate: rounds that each bring a never-seen key are never
stopped. -/
theorem fresh_start_new_rounds_never_fire (t : Thresholds) (trace : List Event)
    (hnew : NewRounds [] trace) : (run t trace fresh).decisions = 0 :=
  new_rounds_never_fire t trace fresh [] (by intro k hk; simp [fresh] at hk) hnew

/-! ## The positive side -/

/-- Something ran and every evidence key is remembered. -/
def StaleRound (seen : List Nat) (r : List Slot) : Prop :=
  r ≠ [] ∧ ∀ sl ∈ r, ∀ k, sl.evidence = some k → k ∈ seen

theorem observe_stale (s : State) (r : List Slot) (h : StaleRound s.seen r) :
    (observe s r).seen = s.seen ∧ (observe s r).staleRounds = s.staleRounds + 1 ∧
      (observe s r).decisions = s.decisions := by
  obtain ⟨hne, hall⟩ := h
  cases r with
  | nil => exact absurd rfl hne
  | cons hd rest =>
    obtain ⟨hseen, hnov⟩ := foldl_stale (hd :: rest) { seen := s.seen, stretch := s.stretch, novel := false } hall
    have hnov' : (scanRound s (hd :: rest)).novel = false := hnov
    have hseen' : (scanRound s (hd :: rest)).seen = s.seen := hseen
    unfold observe
    dsimp only
    rw [if_neg (by rw [hnov']; decide)]
    exact ⟨hseen', rfl, rfl⟩

theorem run_stays_at_budget (t : Thresholds) (trace : List Event) (s : State)
    (h : s.decisions = maxDecisions) : (run t trace s).decisions = maxDecisions :=
  Nat.le_antisymm (decisions_bounded t trace s (Nat.le_of_eq h))
    (h ▸ decisions_monotone t trace s)

/-- From an unspent budget, `staleRounds` consecutive stale rounds (counting
the stretch already under way) always produce exactly one decision. Zig
mirror: "stale trace: varied calls that only return seen answers fire the
stale tier". -/
theorem stale_stretch_fires (t : Thresholds) (rounds : List (List Slot)) (s : State)
    (hbudget : s.decisions = 0)
    (hstale : ∀ r ∈ rounds, StaleRound s.seen r)
    (hne : rounds ≠ [])
    (hlen : t.staleRounds ≤ s.staleRounds + rounds.length) :
    (run t (rounds.map Event.round) s).decisions = maxDecisions := by
  induction rounds generalizing s with
  | nil => exact absurd rfl hne
  | cons r rest ih =>
    obtain ⟨hseen, hsr, hdec⟩ := observe_stale s r (hstale r (List.mem_cons_self _ _))
    simp only [List.map_cons, run, apply]
    unfold step
    split
    · rename_i c hc
      apply run_stays_at_budget
      simp only [hdec, hbudget, maxDecisions]
    · rename_i hnone
      cases rest with
      | nil =>
        exfalso
        -- the last round: its stretch already reaches the stale threshold
        have hlen1 : t.staleRounds ≤ (observe s r).staleRounds := by
          rw [hsr]
          exact hlen
        apply stale_threshold_fires t (observe s r) (by rw [hdec, hbudget]; decide)
          (by rw [hsr]; exact Nat.succ_pos _) hlen1
        exact hnone
      | cons r2 rest2 =>
        apply ih
        · rw [hdec, hbudget]
        · intro r' hr'
          rw [hseen]
          exact hstale r' (List.mem_cons_of_mem _ hr')
        · exact List.cons_ne_nil _ _
        · -- one round moved from the trace into the stretch
          rw [hsr]
          have : s.staleRounds + 1 + (r2 :: rest2).length =
              s.staleRounds + (r :: r2 :: rest2).length := by
            rw [List.length_cons r, Nat.add_right_comm, Nat.add_assoc]
          rw [this]
          exact hlen

end MetaCodesControl.StallGate
