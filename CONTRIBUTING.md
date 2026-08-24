# Contributing

Thank you for improving metacodes. The project is still pre-1.0 and favors small,
evidence-backed changes over broad compatibility promises.

## Before coding

1. Read [AGENTS.md](AGENTS.md) and the relevant document in [doc/](doc/README.md).
2. Open an issue for a new public API, wire-protocol revision, kernel-boundary
   change, or behavior likely to affect prompt bytes and benchmark comparability.
3. Keep paid/model-backed evaluations out of ordinary pull requests. They require
   explicit authorization, a dollar cap, and durable budget receipts.

## Development

Use the Zig version declared in `build.zig.zon` and CI. Build with:

```sh
zig build
zig build test:lib
zig build test
```

TinyKG-dependent work uses the native checked-in bundle by default. Follow the
manual binary contract in [doc/TINYKG_INTEGRATION.md](doc/TINYKG_INTEGRATION.md)
when auditing or replacing it. Do not add a TinyKG source snapshot,
download-on-build step, `PATH` lookup, or sibling-repository fallback.

Every public field or capability needs declaration, runtime wiring, and an L2
test that observes the downstream effect. Update API documentation and source-free
consumer fixtures in the same pull request as an API change.

## Pull requests

- Keep changes focused and explain the user-visible outcome.
- Add tests for failures and illegal-state rejection, not only the happy path.
- Note prompt-cache effects explicitly: unchanged, intentionally invalidated, or
  unknown and therefore blocked.
- Run `git diff --check`, formatting, ReleaseSafe tests proportional to risk, and
  `scripts/test_coverage_audit.sh`.
- Do not include credentials, personal absolute paths, generated benchmark runs,
  local stores, or compiled binaries. The reviewed TinyKG assets declared by
  `vendor/tinykg/manifest.json` are the only binary exception.

By contributing, you agree that your contribution will be distributed under the
project license selected before public launch. Until that license is published,
external contributions should not be accepted or merged.
