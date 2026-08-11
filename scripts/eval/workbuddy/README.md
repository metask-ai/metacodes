# WorkBuddy-Bench integration

WorkBuddy-Bench commit `b516950be5b56eb3be406c2f76ee1c5111dcb57f`
is the pinned external framework.  This directory is the maintained source for
the metacodes overlay; do not hand-edit a WorkBuddy checkout.

Install the idempotent overlay:

```bash
python3 -m scripts.eval.workbuddy.install_overlay /path/to/workbuddy-bench
```

Stage production Linux artifacts with explicit source and license provenance:

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

W0 uses a static synthetic ELF, Docker `network_mode: none`, `n_attempts=1`,
and concurrency 1. The ELF also asserts at runtime that its namespace has no
non-loopback interface. This native compose rule works on Docker Desktop where
Harbor's nftables egress sidecar is unavailable. It verifies adapter
installation, read-only split mount,
anonymous-FD route authority, fresh HOME, isolated local TinyKG, cleared remote
TinyKG configuration, artifact/verifier I/O, ATIF conversion and cache metrics.
It is always marked `quality_evidence=false` and must never be reported as a
memory or task-success result.
