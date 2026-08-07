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

`adapt-longmem-memory` consumes the pinned cleaned LongMemEval-S JSON. It preserves the six official categories,
source position and timestamp, but does not reorder sessions: the cleaned dataset contains deliberate duplicate
non-gold session ids, empty distractor turns, non-chronological array order, and same-day sessions later than the
question clock time. `question_date` is therefore treated as a reasoning reference, not a transaction cutoff.
Each session occurrence receives a distinct stable id, while every gold session id must resolve to exactly one
occurrence. Integer answers are canonically converted to decimal strings.

```bash
python3 -m scripts.eval.cli adapt-longmem-memory \
  --source /path/to/longmemeval_s_cleaned.json \
  --expected-source-sha256 d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442 \
  --execution evals/memory/fixtures/hotpot-adapter-smoke-execution.json \
  --output-source /tmp/longmem-memory-source.json \
  --output-manifest /tmp/longmem-memory-manifest.json \
  --limit 500 \
  --split-seed 20260806
```

The importable source slice strips `answer`, `answer_session_ids`, every `has_answer` flag, raw question ids and
the public `_abs` suffix. The host-owned manifest retains answer and session-level evidence. For abstention cases,
the official `answer_session_ids` are treated as relevant near-miss evidence that justifies the refusal; they are
not erased from the retrieval denominator. As with HotpotQA, the smoke execution identity is not a paid rollout
configuration.

### Multi-hop retrieval

Use the 1,000-example HippoRAG-preprocessed HotpotQA subset or a pinned smaller smoke split. Freeze `K=10` and
maximum hop depth (default 3). Record gold supporting-fact ids, retrieved ids, verified ids, exact query,
semantic variants, and per-hop candidates. Report EM, token F1, evidence recall/precision, all-support coverage,
query count, hop count, fan-out, and graph truncation. Include no-context and oracle-gold-context controls.

The repository adapter consumes the official `hotpot_dev_distractor_v1.json` shape. It validates every source
record, rejects duplicate ids/titles/supports and missing or out-of-range support ids, then selects cases by
`SHA256(split_seed || NUL || source_id)` rather than input order. A known upstream annotation defect may only be
excluded through a source-SHA-bound quarantine policy that exactly matches the observed defect; unused or stale
exclusions fail closed.

```bash
python3 -m scripts.eval.cli adapt-hotpot-memory \
  --source /path/to/hotpot_dev_distractor_v1.json \
  --expected-source-sha256 <pinned-source-sha256> \
  --execution evals/memory/fixtures/hotpot-adapter-smoke-execution.json \
  --output-source /tmp/hotpot-memory-source.json \
  --output-manifest /tmp/hotpot-memory-manifest.json \
  --limit 1000 \
  --split-seed 20260806
```

The output source slice is safe to import as a candidate corpus: it contains questions, titles, sentence ids and
text, but no answers, gold support ids, or `supporting` labels. The separate host-owned manifest contains hidden
answers/support ids and is the only artifact passed to deterministic scoring. Do not expose the manifest to the
agent or import it into the treatment graph. The execution file shown above is for zero-rollout adapter smoke
only; a real experiment must replace it with the actual model, harness, arm and trial fingerprints.
The checked-in `pins/hotpotqa-dev-distractor-1000-pin.json` records the mirror distribution, conversion,
quarantine, ordered sample and generated artifact hashes without redistributing benchmark questions or answers.

### Procedural transfer

Create intent-template families from coding tasks: one instance per template is `online` (insert+retrieve),
remaining sibling instances are `offline` (read-only retrieval). A fresh agent receives the resulting graph
without the online transcript. Report online/offline success, transfer gain over cold start, first-attempt
success, repair/rollback count, tool/turn/token/cost, and any offline write leakage. Human demonstrations, if
used, are a separately named factor and never silently included.

`adapt-procedural-memory` freezes complete intent families rather than sampling sibling cases independently.
Each selected family must contain exactly one online case and at least two offline cases. The raw host-owned
source includes baseline inline workspaces, deterministic workspace assertions, and oracle replacements used
only to prove that the baseline fails and a known solution passes. The public source slice strips the assertions
and oracle while retaining every baseline file plus workspace, task, intent-template, and validator fingerprints.
The separate validator bundle strips the oracle too and is bound to the public source hash; its per-case
fingerprint is the manifest grader identity. No LLM judge, shell command, network request, or TinyKG instance is
used during adaptation.

```bash
source_sha=$(shasum -a 256 evals/memory/fixtures/procedural-coding-source.json | cut -d' ' -f1)
python3 -m scripts.eval.cli adapt-procedural-memory \
  --source evals/memory/fixtures/procedural-coding-source.json \
  --expected-source-sha256 "$source_sha" \
  --execution evals/memory/fixtures/procedural-adapter-smoke-execution.json \
  --output-source /tmp/procedural-memory-source.json \
  --output-validators /tmp/procedural-memory-validators.json \
  --output-manifest /tmp/procedural-memory-manifest.json \
  --limit-families 2 \
  --split-seed 20260806
```

The generated schedule is family-causal for every arm and trial: the online case is always observed before any
offline sibling. Actual runners must materialize each workspace afresh, execute the host-owned validator after
the agent stops, and compare the graph revision around every offline run. Offline and read-only arms must report
zero inserts and zero write events. The checked fixture is an adapter/validator trace, not evidence that one
memory arm improves coding success.

### Local TinyKG isolation smoke

Benchmark corpora must never be sent through the user-level TinyKG skill harness because that harness may be
configured for the remote canonical memory store. `smoke-local-tinykg-memory` instead invokes a hash-pinned
TinyKG executable directly. It requires a fresh run directory, creates every store below that directory, gives
children a sealed `HOME`, removes `TINYKG_STORE` and every `TINYKG_REMOTE_*` variable, and passes the store path
positionally on every command. The smoke supports all three adapters: Hotpot documents/sentences,
LongMemEval sessions/turns, and procedural online-evidence/offline-query families.

```bash
tinykg_sha=$(shasum -a 256 zig-out/vendor/tinykg/tinykg | cut -d' ' -f1)
python3 -m scripts.eval.cli smoke-local-tinykg-memory \
  --binary zig-out/vendor/tinykg/tinykg \
  --expected-binary-sha256 "$tinykg_sha" \
  --source /tmp/procedural-memory-source.json \
  --manifest /tmp/procedural-memory-manifest.json \
  --run-dir /tmp/metacodes-procedural-local-run \
  --output /tmp/metacodes-procedural-local-run/trace.json \
  --case-limit 1
```

The loader emits a TinyKG `apply` batch containing only public corpus fields. It then records lexical hits and a
bounded graph-neighbor probe. A full content digest of the store is taken after online/import writes and again
after `store-info`, `search`, and `neighbors`; any content change during this read-only phase fails the run. The
trace records `skill_harness_invocations=0`, `remote_api_calls=0`, and `remote_store_writes=0`, along with binary,
source, manifest, batch, and graph-revision hashes. These are isolation and plumbing claims, not memory-quality
scores. Actual outcome experiments still require scheduled agent executions, deterministic grading, runtime
receipts, repeated trials, and confidence intervals.

The graph revision normalizes only TinyKG's volatile `migration.recorded_ns` creation timestamp; the stricter
read-only guard still hashes the raw manifest and every store file/directory, so normalization cannot hide a
write during retrieval. This makes equivalent fresh stores comparable while preserving fail-closed write-leak
detection.

## Result row contract

Each v2 JSONL row is validated by `scripts.eval.memory_benchmark` and must bind:

- protocol/benchmark/case/sequence/trial/arm/split;
- dataset SHA-256, adapter id/revision, split seed, manifest/runtime-receipt/observation SHA-256,
  task fingerprint, model id+fingerprint, harness revision, arm fingerprint and grader fingerprint;
- execution validity, evaluator validity and outcome success as three separate states;
- answer/gold answers where applicable;
- retrieval evidence sets, query variants, hop count and truncation;
- exposed/internal tokens and cost/latency;
- input graph revision, provenance and governance counters.

Rows with invalid execution or evaluator state remain in the artifact for audit but are excluded from outcome
denominators. Missing evidence is not interpreted as a failed answer; it is reported as a retrieval miss.
An empty model prediction is different: it is retained as a scored failure so silence cannot disappear from the
denominator.

## Frozen replay boundary

`replay-memory` joins three deliberately separate artifacts:

- the case manifest owns prompts, hidden gold answers/support ids, dataset and adapter identity, arm/model/grader
  fingerprints, trial count, retrieval limits, and every ordered `(sequence, case, trial, arm)` schedule entry;
- observation JSONL owns only host-observed execution/evaluator state, prediction, retrieval trace, graph/memory
  counters, cost and trajectory. It cannot provide gold answers, outcome success, arm fingerprints, or the
  denominator.
- the host-owned runtime receipt records the identities actually used and binds canonical manifest,
  observations, dataset, adapter, model, harness, arms and graders. Replay rejects any mismatch instead of
  copying expected identities onto unverified observations.

The manifest must contain exactly one online case per procedural family and schedule it before all offline
siblings for every arm/trial. Observations must occur in that frozen line order, with no missing or duplicate
tuple. Replay recomputes QA exact match from hidden manifest gold and accepts procedural success only from the
pinned deterministic validator. A scored non-control offline row must use the same graph revision as its online
predecessor, and that predecessor must have valid execution and evaluator state.

Fail-closed invariants include:

- `no_memory` disables retrieval and memory writes and reports zero memory counters;
- disabled retrieval cannot report retrieved or verified evidence;
- `read_only`, `disabled`, and every offline row have zero inserted nodes;
- an invalid execution does not invent a procedural success boolean;
- prompts cannot contain treatment labels;
- dataset bytes, manifest, observations, task, model, harness, arm and grader are hash-bound.

Zero-cost smoke:

```bash
python3 -m scripts.eval.cli replay-memory \
  --manifest evals/memory/fixtures/smoke-manifest.json \
  --observations evals/memory/fixtures/smoke-observations.jsonl \
  --dataset-source evals/memory/fixtures/smoke-source.json \
  --runtime-receipt evals/memory/fixtures/smoke-runtime-receipt.json \
  --output /tmp/memory-maturation-smoke.jsonl \
  --markdown /tmp/memory-maturation-smoke.md \
  --json /tmp/memory-maturation-smoke-summary.json
```

## Metrics hierarchy

Headline: trustworthy outcome success/EM/F1 and evidence recall. Secondary: transfer gain, provenance/freshness
governance, exposed/internal cost, latency and graph compactness. Optional: PlugMem-style smoothed PMI density
(bits per exposed memory token), always labeled as a derived utility-cost statistic.

## Reproducibility rules

Use a deterministic split seed, stable JSON, immutable dataset/artifact revisions, and an explicitly frozen
ordered schedule. Keep raw transcript/events and TinyKG graph revision with each row. Run the synthetic smoke
fixture and metric unit tests before any paid or external benchmark execution. The smoke fixture validates the
adapter and scoring boundary; it is not scientific evidence of memory quality.
