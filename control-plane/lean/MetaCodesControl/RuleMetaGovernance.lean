import Std

/-! # Rule meta-governance: the constitution for rule changes

Rules about changing rules, so an LLM can eventually author rule-revision
proposals at runtime while the *change process* stays provably safe.  The
articles were reviewed against this campaign's adjudicated history:

* M1 asymmetric evidence — widening (less protection) requires adjudicated
  false-intervention evidence; narrowing (more blocking) accepts adjudicated
  miss evidence OR a declared threat analysis, but never skips shadow.
* M2 shadow-first for blocking increases; an evidenced widening may take the
  expedited path but always under the M4 tripwire.
* M3 non-harm gate — promotion requires a counterfactual receipt with
  declared uncertainty, bound to exact bundle/kernel/instrument hashes.
* M4 reversibility — every promotion pins its predecessor; an enforced-block
  budget tripwire demotes to shadow mechanically (rate-based, never a
  verdict: adjudication stays human).
* M5 capability non-escalation — LLM-authored proposals can never carry deny
  power; deny stays human-signed.
* M6 goal anchoring — proposals must be graph-anchored to a long-term goal
  and to their evidence nodes.
* M7 window separation — generation and evaluation windows must not overlap.
* M8 instrument-first — no promotion until the auditor suite attests it can
  read artifacts produced under the new rule (eight field incidents).
* M9 actionable blocks — a rule whose blocks carry no actionable hint cannot
  promote (the twelve-turn confusion spiral).

Empirical outcomes are never proven here — only that the required evidence
exists, is bound, and that the feedback loop is bounded and reversible. -/

namespace MetaCodesControl.RuleMetaGovernance

inductive ChangeKind where
  | widening
  | narrowing
  | newRule
  deriving Repr, BEq, DecidableEq

inductive Author where
  | human
  | llm
  deriving Repr, BEq, DecidableEq

structure Proposal where
  kind : ChangeKind
  author : Author
  carriesDeny : Bool
  /-- Hash-bound, human-adjudicated false-intervention evidence count. -/
  falseInterventionEvidence : Nat
  /-- Hash-bound, human-adjudicated missed-hazard evidence count. -/
  missEvidence : Nat
  threatAnalysisDeclared : Bool
  goalAnchored : Bool
  evidenceAnchored : Bool
  blockHintDeclared : Bool
  predecessorPinned : Bool
  deriving Repr, BEq

structure ShadowStats where
  observations : Nat
  windowDisjointFromEval : Bool
  deriving Repr, BEq

structure CounterfactualReceipt where
  present : Bool
  instrumentBound : Bool
  auditorAttested : Bool
  nonHarmDeclared : Bool
  deriving Repr, BEq

/-- M1/M2 asymmetric evidence-and-shadow admission. -/
def evidenceAdmits (p : Proposal) (s : ShadowStats) (minShadow : Nat) : Bool :=
  match p.kind with
  | .widening => p.falseInterventionEvidence > 0
  | .narrowing =>
      (p.missEvidence > 0 || p.threatAnalysisDeclared) &&
        s.observations ≥ minShadow
  | .newRule => s.observations ≥ minShadow

/-- The promotion gate: every article conjoined. -/
def mayPromote (p : Proposal) (s : ShadowStats) (c : CounterfactualReceipt)
    (minShadow : Nat) : Bool :=
  (!p.carriesDeny || p.author == .human) &&
  p.goalAnchored && p.evidenceAnchored &&
  p.blockHintDeclared &&
  p.predecessorPinned &&
  s.windowDisjointFromEval &&
  c.present && c.instrumentBound && c.auditorAttested && c.nonHarmDeclared &&
  evidenceAdmits p s minShadow

/-- M4 tripwire: rate-based, never a verdict. -/
def tripwire (enforcedBlocks budget : Nat) : Bool :=
  enforcedBlocks > budget

inductive Stage where
  | draft
  | shadow
  | promoted
  | demoted
  deriving Repr, BEq, DecidableEq

/-- Demotion on tripwire is total from the promoted stage: it needs no
evidence, no receipt and no adjudication — protection first, review after. -/
def step (stage : Stage) (tripped : Bool) : Stage :=
  match stage, tripped with
  | .promoted, true => .demoted
  | s, _ => s

-- M5 --------------------------------------------------------------------
theorem llm_cannot_promote_deny (p : Proposal) (s : ShadowStats)
    (c : CounterfactualReceipt) (minShadow : Nat)
    (author : p.author = .llm) (deny : p.carriesDeny = true) :
    mayPromote p s c minShadow = false := by
  simp [mayPromote, author, deny]
  intro h
  cases h

-- M6 --------------------------------------------------------------------
theorem unanchored_cannot_promote (p : Proposal) (s : ShadowStats)
    (c : CounterfactualReceipt) (minShadow : Nat)
    (h : p.goalAnchored = false) :
    mayPromote p s c minShadow = false := by
  simp [mayPromote, h]

theorem evidence_unanchored_cannot_promote (p : Proposal) (s : ShadowStats)
    (c : CounterfactualReceipt) (minShadow : Nat)
    (h : p.evidenceAnchored = false) :
    mayPromote p s c minShadow = false := by
  simp [mayPromote, h]

-- M1 --------------------------------------------------------------------
theorem widening_requires_adjudicated_false_intervention (p : Proposal)
    (s : ShadowStats) (c : CounterfactualReceipt) (minShadow : Nat)
    (kind : p.kind = .widening)
    (no_evidence : p.falseInterventionEvidence = 0) :
    mayPromote p s c minShadow = false := by
  simp [mayPromote, evidenceAdmits, kind, no_evidence]

-- M2 --------------------------------------------------------------------
theorem narrowing_requires_shadow_window (p : Proposal) (s : ShadowStats)
    (c : CounterfactualReceipt) (minShadow : Nat)
    (kind : p.kind = .narrowing)
    (short : s.observations < minShadow) :
    mayPromote p s c minShadow = false := by
  simp [mayPromote, evidenceAdmits, kind, Nat.not_le_of_lt short]

-- M3 / M8 ---------------------------------------------------------------
theorem no_promotion_without_counterfactual (p : Proposal) (s : ShadowStats)
    (c : CounterfactualReceipt) (minShadow : Nat)
    (h : c.present = false) :
    mayPromote p s c minShadow = false := by
  simp [mayPromote, h]

theorem unbound_instrument_cannot_promote (p : Proposal) (s : ShadowStats)
    (c : CounterfactualReceipt) (minShadow : Nat)
    (h : c.instrumentBound = false) :
    mayPromote p s c minShadow = false := by
  simp [mayPromote, h]

theorem unattested_auditor_cannot_promote (p : Proposal) (s : ShadowStats)
    (c : CounterfactualReceipt) (minShadow : Nat)
    (h : c.auditorAttested = false) :
    mayPromote p s c minShadow = false := by
  simp [mayPromote, h]

-- M7 --------------------------------------------------------------------
theorem overlapping_window_cannot_promote (p : Proposal) (s : ShadowStats)
    (c : CounterfactualReceipt) (minShadow : Nat)
    (h : s.windowDisjointFromEval = false) :
    mayPromote p s c minShadow = false := by
  simp [mayPromote, h]

-- M9 --------------------------------------------------------------------
theorem bare_block_cannot_promote (p : Proposal) (s : ShadowStats)
    (c : CounterfactualReceipt) (minShadow : Nat)
    (h : p.blockHintDeclared = false) :
    mayPromote p s c minShadow = false := by
  simp [mayPromote, h]

-- M4 --------------------------------------------------------------------
theorem unpinned_predecessor_cannot_promote (p : Proposal) (s : ShadowStats)
    (c : CounterfactualReceipt) (minShadow : Nat)
    (h : p.predecessorPinned = false) :
    mayPromote p s c minShadow = false := by
  simp [mayPromote, h]

theorem tripwire_always_demotes (tripped : Bool)
    (h : tripped = true) :
    step .promoted tripped = .demoted := by
  simp [step, h]

theorem quiet_rules_stay_promoted :
    step .promoted false = .promoted := by
  simp [step]

/-- The expedited widening path exists and is safe by construction: an
adjudicated false intervention plus every gate article admits promotion with
zero shadow observations — and the tripwire (M4) still guards it after. -/
theorem evidenced_widening_may_expedite (p : Proposal) (s : ShadowStats)
    (c : CounterfactualReceipt) (minShadow : Nat)
    (kind : p.kind = .widening)
    (evidence : p.falseInterventionEvidence > 0)
    (human_or_verify : (!p.carriesDeny || p.author == .human) = true)
    (goal : p.goalAnchored = true) (anchored : p.evidenceAnchored = true)
    (hint : p.blockHintDeclared = true) (pinned : p.predecessorPinned = true)
    (window : s.windowDisjointFromEval = true)
    (receipt : c.present = true) (bound : c.instrumentBound = true)
    (attested : c.auditorAttested = true) (nonharm : c.nonHarmDeclared = true) :
    mayPromote p s c minShadow = true := by
  simp [mayPromote, evidenceAdmits, kind, evidence, human_or_verify, goal,
    anchored, hint, pinned, window, receipt, bound, attested, nonharm]

end MetaCodesControl.RuleMetaGovernance
