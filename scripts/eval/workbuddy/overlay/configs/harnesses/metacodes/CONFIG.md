# metacodes WorkBuddy harness

The harness is delivered as a read-only split mount.  `install()` verifies
`share/metacodes/SHA256SUMS` before linking the launcher; it never downloads a
fallback package.

Runtime invariants:

- `model_connection` must be `local_proxy`;
- the host proxy owns the real provider credential and request retry policy;
- the trial gets only a route token, passed to metacodes through an inherited
  anonymous descriptor;
- every trial creates a fresh HOME and local `METACODES_KG_STORE`;
- all `TINYKG_REMOTE_*` variables, `TINYKG_API_KEY`, and legacy
  `METASK_API_KEY` are cleared before the process starts;
- the TinyKG and Lean sidecars come from the same hash-pinned mount;
- the adapter captures metacodes NDJSON and transcript JSONL, then emits ATIF.

`scripts/eval/workbuddy/stage_artifacts.py` creates the `docker/artifacts/`
tree.  Generated binaries are intentionally not tracked by the metacodes
repository or the WorkBuddy overlay.
