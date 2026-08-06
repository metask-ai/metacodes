# memory-maturation-v1

This is a separate, zero-cost-capable memory evaluation protocol inspired by PlugMem. It is not part of the
frozen `metacodes-long-horizon-pk-v2` calibration/confirmatory schedule.

## Research questions

| RQ | Benchmark family | Primary question |
|---|---|---|
| R1 | `episodic_recall` (LongMemEval-S shaped) | Does persistent memory recover the right historical fact under a long context and temporal update? |
| R2 | `multihop_retrieval` (HotpotQA shaped) | Does TinyKG's lexical + graph route recover all supporting evidence without vectors? |
| R3 | `procedural_transfer` (WebArena online/offline shaped) | Does an online task improve a held-out sibling task when memory writes are disabled offline? |
| R4 | governance/structure side metrics | Is the retrieved memory evidence-backed, fresh, compact, and free of leakage? |

## Arms and controls

The exact arms are frozen per experiment, but a minimal comparison is:

- `no_memory`: no external memory or graph retrieval;
- `markdown_memory`: existing Markdown/session memory only;
- `tinykg_lexical`: TinyKG retrieval with exact query, then at most four separate LLM-selected semantic
  variants, followed by bounded graph traversal and `KgContext` verification;
- optional `tinykg_ablation_exact_only`, `tinykg_ablation_no_graph`, and `tinykg_ablation_no_provenance`.

The same model, task, tool budget, context limit, and grader are required across arms. Ablations are separate
from the primary treatment and must not be mixed into the three-arm PK result.

## Benchmark-specific protocol

### Episodic recall

Pin a LongMemEval-S dataset revision and preserve the official category labels. Evaluate at least the six
categories (single-session user/assistant/preference, knowledge update, temporal reasoning, multi-session).
Construct memory before the question, reset the agent context, and record answer plus the retrieved source
session/message ids. Report normalized EM/F1 when references permit; official LLM judge accuracy is a secondary
comparison only.

### Multi-hop retrieval

Use the 1,000-example HippoRAG-preprocessed HotpotQA subset or a pinned smaller smoke split. Freeze `K=10` and
maximum hop depth (default 3). Record gold supporting-fact ids, retrieved ids, verified ids, exact query,
semantic variants, and per-hop candidates. Report EM, token F1, evidence recall/precision, all-support coverage,
query count, hop count, fan-out, and graph truncation. Include no-context and oracle-gold-context controls.

### Procedural transfer

Create intent-template families from coding tasks: one instance per template is `online` (insert+retrieve),
remaining sibling instances are `offline` (read-only retrieval). A fresh agent receives the resulting graph
without the online transcript. Report online/offline success, transfer gain over cold start, first-attempt
success, repair/rollback count, tool/turn/token/cost, and any offline write leakage. Human demonstrations, if
used, are a separately named factor and never silently included.

## Result row contract

Each JSONL row is validated by `scripts.eval.memory_benchmark` and must bind:

- protocol/benchmark/case/trial/arm/split;
- dataset SHA-256, task fingerprint, model id, harness revision and grader fingerprint;
- execution validity and outcome success;
- answer/gold answers where applicable;
- retrieval evidence sets, query variants, hop count and truncation;
- exposed/internal tokens and cost/latency;
- graph/provenance and governance counters.

Rows with invalid execution or evaluator state remain in the artifact for audit but are excluded from outcome
denominators. Missing evidence is not interpreted as a failed answer; it is reported as a retrieval miss.

## Metrics hierarchy

Headline: trustworthy outcome success/EM/F1 and evidence recall. Secondary: transfer gain, provenance/freshness
governance, exposed/internal cost, latency and graph compactness. Optional: PlugMem-style smoothed PMI density
(bits per exposed memory token), always labeled as a derived utility-cost statistic.

## Reproducibility rules

Use a deterministic split seed, stable JSON, immutable dataset/artifact revisions, and order-balanced paired
trials. Keep raw transcript/events and TinyKG graph revision with each row. Run the synthetic smoke fixture and
metric unit tests before any paid or external benchmark execution.
