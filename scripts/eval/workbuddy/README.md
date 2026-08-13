# WorkBuddy-Bench integration

WorkBuddy-Bench commit `b516950be5b56eb3be406c2f76ee1c5111dcb57f`
is the pinned external framework.  This directory is the maintained source for
the metacodes overlay; do not hand-edit a WorkBuddy checkout.

Install the idempotent overlay:

```bash
python3 -m scripts.eval.workbuddy.install_overlay /path/to/workbuddy-bench
```

Stage production `linux/amd64` artifacts with explicit source and license
provenance. The stager parses every ELF header and rejects ARM64 or mixed-arch
inputs before creating the output directory:

```bash
python3 -m scripts.eval.workbuddy.stage_artifacts \
  --output /path/to/workbuddy-bench/configs/harnesses/metacodes/docker/artifacts \
  --metacodes /path/to/linux/metacodes \
  --tinykg /path/to/linux/tinykg \
  --formal-kernel /path/to/linux/metacodes-formal-kernel \
  --metacodes-commit <40-hex> --tinykg-commit <40-hex> \
  --metacodes-license /path/to/LICENSE --metacodes-license-spdx NOASSERTION \
  --tinykg-license /path/to/tinykg/LICENSE \
  --lean-license /path/to/lean4/LICENSE
```

The repository currently has no repository-wide metacodes license.  Until that
changes, production staging must use
`scripts/eval/workbuddy/licenses/METACODES-NOASSERTION.txt` together with
`--metacodes-license-spdx NOASSERTION`; the artifact manifest preserves that
fact instead of implying a license grant.

Run the zero-provider W0 vertical slice:

```bash
python3 -m scripts.eval.workbuddy.run_w0 /path/to/workbuddy-bench
```

Run the first WorkBuddy W0.5 real-control slice with a fresh checkout.  It is
still a local scripted-provider test, not a memory-quality score: it proves
the official Harbor/Docker path, real TinyKG and project Lean gate, and a
single synthetic task while making zero external/paid requests.  The runner
retains only a hash-bound receipt and derived control metrics; raw traces stay
in the isolated local checkout.  The pinned Harbor Docker backend on macOS
does not implement allowlist/no-network phase policies, so W0.5 must use its
`public` mode to reach the host proxy; the only configured upstream route is
the runner-owned loopback scripted provider and the receipt audits all eight
requests.

```bash
python3 -m scripts.eval.workbuddy.run_w05 /path/to/fresh-workbuddy-bench \
  --metacodes /path/to/linux-amd64/metacodes \
  --tinykg /path/to/linux-amd64/tinykg \
  --formal-kernel /path/to/linux-amd64/metacodes-formal-kernel \
  --project-kernel /path/to/linux-amd64/metacodes-project-kernel \
  --project-rules /path/to/promoted/project-rules \
  --metacodes-commit <40-hex> --tinykg-commit <40-hex> \
  --metacodes-license /path/to/METACODES-NOASSERTION.txt \
  --tinykg-license /path/to/tinykg/LICENSE \
  --lean-license /path/to/lean4/LICENSE
```

The W0.5 receipt must remain `quality_evidence=false`.  Do not reuse its
synthetic task or scripted request log as a memory benchmark result, and do
not widen the sample until its negative/tamper gates and the next wave have
been reviewed.

Freeze the official task cohorts before inspecting any task body:

```bash
python3 -m scripts.eval.workbuddy.cohort_manifest \
  --workbuddy-checkout /path/to/workbuddy-bench \
  --archives-dir /path/to/downloaded-but-not-extracted-archives \
  --sha256sums /path/to/SHA256SUMS \
  --output /path/to/workbuddy-cohorts-v1.json
```

The generator has a fixed salt and quota table. It verifies each official
archive, scans only tar member headers ending in `tasks/<slug>/task.toml`, and
does not extract or open task instructions, tests, or workspaces. Each generated
cohort contains the exact `task_selection: {mode: name, names: [...]}` mapping
accepted by WorkBuddy jobs. Commit the generator before obtaining official task
slugs; keep the resulting manifest immutable and bind it into every paid run.

Paid WorkBuddy model configs must name
`METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF` as `backend_key_env`. The launch gate
sets that variable to an `fd://N` reference only after durable budget
authorization. The patched host proxy consumes and closes the anonymous
descriptor; a raw secret in this dedicated environment variable is rejected.
Normal upstream WorkBuddy model configs keep their existing environment-key
behavior. Production metacodes pilots must not use the shared proxy because its
long-lived credential lifecycle is outside the single-run budget transaction.

The paid launch gate is separate from the normal WorkBuddy runner. `create`
performs a provider-side-effect-free plan and binds the cohort, WorkBuddy
commit/overlay, linux/amd64 split-mount hashes, job/model configs, caps and
cache policy. Before `create`, prebuild the selected task environments. This
warms Harbor's BuildKit cache and writes a private receipt binding every Docker
context hash, resulting image ID, the split-mount image and Docker client:

```bash
python3 -m scripts.eval.workbuddy.environment_preflight \
  --workbuddy-checkout /path/to/workbuddy-bench \
  --dataset datasets/wb-bench-code-v1.0/tasks \
  --task <frozen-task-1> --task <frozen-task-2> --task <frozen-task-3> \
  --output /private/preflight.json
```

The launch manifest requires that receipt plus absolute, hashed GNU Bash 4+
and `uv` executables. It also binds the Python launcher, journal, preflight,
overlay, stager, credential-FD and model helpers. `run` re-observes those
identities and the cached linux/amd64 images, sets
`DOCKER_DEFAULT_PLATFORM=linux/amd64`, appends
`request_authorized` to the external journal, then starts the fixed WorkBuddy
command with the anonymous credential FD. It commits only after every selected
trajectory has a request audit, usage, cache-prefix hash, transcript and a
complete tool-observation journal. The launch gate independently recomputes
bounded post-run metrics for real tool dispatches, Lean verdicts/timing,
TinyKG recall/context/remember and task-DAG activity; trajectory self-reports
are not trusted. Per-task receipt rows bind the transcript and journal hashes,
while wave summaries aggregate counts and preserve maxima. Raw tool arguments,
results and memory text remain in isolated local trial artifacts and are not
copied into the derived metrics. A failed or interrupted authorized run is not
automatically retried.

For official datasets, preflight also requires and hash-binds the dataset-level
`dataset.toml`. When it selects the composite verifier, the complete
`shared/verifier` implementation is bound and re-observed before authorization.
A checkout containing only selected task directories is not a runnable official
dataset and fails before credential loading, journal mutation, or provider I/O.

If the runner returns nonzero after authorization, the gate writes a separate
`metacodes-workbuddy-authorized-failure-v2` receipt before reporting the
failure. It keeps the journal transaction in `request_authorized`, reports
actual cost/tokens as unknown, marks `quality_evidence=false` and
`retry_allowed=false`, and binds only bounded status/count/timing summaries
plus hashes of local artifacts. It never copies credentials, request/response
bodies, error text or memory text into the receipt. A hard crash can still
occur before this diagnostic is published; the durable journal remains the
authority and continues charging the transaction maximum in that case.

Committed token usage includes uncached prompt, completion, cache-read and
cache-creation tokens. Cache accounting is not allowed to disappear merely
because the provider reports those fields separately.

Receipt evidence classification is also frozen before authorization. Omit
`--quality-evidence-on-commit` for Mock, smoke, preflight and infrastructure
runs; their committed receipts remain `quality_evidence=false` even though
they use the official runner. Pass it only for a preregistered real-provider
wave whose official task outcomes are intended to count as quality evidence.
Every such wave must also carry an explicit `--comparison-id`; a single arm is
not sufficient quality evidence for a harness change.

Project-rule outcome studies use two independently created launch manifests
with the same comparison id and frozen covariate digest. The baseline job uses
`METACODES_PROJECT_CONTROL_MODE=disabled`: it mounts and verifies the exact
same rule tree and compiled kernel, but does not materialize
`$HOME/.metacodes/projects/<project>/project-rules/active.json`. The treatment
uses `enforced`. Each arm has a distinct run id, budget journal and budget
transaction. After both official receipts commit, build the paired report with:

```bash
python3 -m scripts.eval.workbuddy.paired_analysis \
  --baseline-manifest /private/baseline-manifest.json \
  --baseline-receipt /private/baseline-receipt.json \
  --baseline-budget-journal /private/baseline-budget.json \
  --treatment-manifest /private/treatment-manifest.json \
  --treatment-receipt /private/treatment-receipt.json \
  --treatment-budget-journal /private/treatment-budget.json \
  --output /private/paired-report.json
```

The analyzer replays both journal hash chains, binds official Harbor verifier
rewards, requires identical per-task cacheable first-request hashes and reports
success, time, cost, token, cache and Lean deltas. Its conclusion is only an
observed paired difference for that frozen cohort and rule bundle. With one
model sample per arm it is not a causal effect estimate, and
`quality_evidence=true` is possible only when both input receipts independently
carry quality evidence.

The overlay also keeps the opaque local-proxy route free of Harbor's ``__``
eval-group delimiter. Otherwise a completed multi-task job can fail only while
Harbor formats its final summary, after all provider and scorer work has run.

```bash
python3 -m scripts.eval.workbuddy.launch_gate create ... \
  --environment-preflight-receipt /private/preflight.json \
  --runner-bash /absolute/path/to/bash \
  --runner-uv /absolute/path/to/uv \
  --output launch.json
# Real scored waves add both:
#   --quality-evidence-on-commit --comparison-id <frozen-pair-id>
python3 -m scripts.eval.workbuddy.launch_gate run \
  --manifest launch.json --budget-journal /private/budget.json \
  --receipt /private/receipts/run.json --credential-fd 9
```

The command above is a protocol sketch; no real paid run is authorized until
the production split mount, launch-gate L2, and the phase-specific manifest
have all passed.

The first paid cohort is frozen in
`configs/jobs/metacodes-glm52-code-3-canary.yaml` by the maintained overlay.  It
selects the first three Code `dev` tasks from the committed cohort manifest,
uses one attempt and one concurrent trial, and records complete provider I/O.
Its backend model id is the provider-catalog spelling `glm-5.2`; model ids are
case-sensitive and must not be normalized by the benchmark adapter.
When provider recovery is uncertain, first use
`metacodes-glm52-code-1-probe.yaml`, which freezes only the first task under the
same single-attempt, single-concurrency and full-I/O rules. A failed probe is
not widened to Code-3.
Do not widen that job in place; later Code16 and cross-domain waves get separate
job files and budget transactions.

The maturation order is intentionally progressive rather than a full-suite
launch: W0 synthetic → optional one-task provider-recovery probe → Code-3
canary → Code-16 development slice → all 52 development tasks → promotion A
(26) → promotion B (26) → sealed holdout (156). Each wave is a separate frozen
manifest and budget transaction, and widening requires human review of the
previous wave's success, drift, cost, elapsed time, stability, cache and
Lean/TinyKG control metrics. Full 260-task repeated runs are optional final
evidence, never the starting point.

W0 uses a static synthetic ELF, Docker `network_mode: none`, `n_attempts=1`,
and concurrency 1. The ELF also asserts at runtime that its namespace has no
non-loopback interface. This native compose rule works on Docker Desktop where
Harbor's nftables egress sidecar is unavailable. It verifies adapter
installation, read-only split mount,
anonymous-FD route authority, fresh HOME, isolated local TinyKG, cleared remote
TinyKG configuration, artifact/verifier I/O, ATIF conversion and cache metrics.
It is always marked `quality_evidence=false` and must never be reported as a
memory or task-success result.
