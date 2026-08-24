## Outcome

Describe the user-visible result and why this boundary is the right one.

## Contract impact

- [ ] No public API/ABI/protocol change
- [ ] Documentation and source-free consumer fixtures updated
- [ ] Provider-visible bytes unchanged
- [ ] Cache invalidation is intentional and tested
- [ ] TinyKG contract unchanged or explicitly revised

## Evidence

- [ ] Declaration, wiring, and L2 behavior are all covered
- [ ] `zig build test:lib -Doptimize=ReleaseSafe`
- [ ] `zig build test -Doptimize=ReleaseSafe`
- [ ] `scripts/test_coverage_audit.sh`
- [ ] No paid/model-backed evaluation was run without explicit authorization
- [ ] No secrets, personal paths, stores, generated runs, or binaries were added
