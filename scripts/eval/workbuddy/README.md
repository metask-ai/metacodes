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
trajectory has a request audit, usage and cache-prefix hash. A failed or
interrupted authorized run is not automatically retried.

Committed token usage includes uncached prompt, completion, cache-read and
cache-creation tokens. Cache accounting is not allowed to disappear merely
because the provider reports those fields separately.

The overlay also keeps the opaque local-proxy route free of Harbor's ``__``
eval-group delimiter. Otherwise a completed multi-task job can fail only while
Harbor formats its final summary, after all provider and scorer work has run.

```bash
python3 -m scripts.eval.workbuddy.launch_gate create ... \
  --environment-preflight-receipt /private/preflight.json \
  --runner-bash /absolute/path/to/bash \
  --runner-uv /absolute/path/to/uv \
  --output launch.json
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
Do not widen that job in place; later Code16 and cross-domain waves get separate
job files and budget transactions.

W0 uses a static synthetic ELF, Docker `network_mode: none`, `n_attempts=1`,
and concurrency 1. The ELF also asserts at runtime that its namespace has no
non-loopback interface. This native compose rule works on Docker Desktop where
Harbor's nftables egress sidecar is unavailable. It verifies adapter
installation, read-only split mount,
anonymous-FD route authority, fresh HOME, isolated local TinyKG, cleared remote
TinyKG configuration, artifact/verifier I/O, ATIF conversion and cache metrics.
It is always marked `quality_evidence=false` and must never be reported as a
memory or task-success result.
