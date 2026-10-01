# Installation, per-install state, and bundled governance kernels

Status: in progress (one PR). Owner of the decisions below: the maintainer;
this document records them so the implementation and reviews have one source.

## 1. Principles

1. **Multi-platform and complete by default.** Every supported platform
   (release targets: `x86_64-linux-gnu`, `aarch64-macos`, `x86_64-windows-gnu`)
   installs with the TUI, the complete TinyKG (`tinykg` + `tinykgd`), and both
   Lean governance kernels. No user-side Lean toolchain is required.
2. **The core is an SDK; the TUI is a thin shell.** `metacodes-core`
   (`src/lib.zig`) and the AgentCore binary bundle never decide *where* state
   lives. The host (the CLI/TUI `main`, or an embedding application) resolves
   the state root and passes it in, exactly as AgentCore already receives
   `workspace_home`.
3. **Installs coexist and are isolated.** One machine may carry several
   installs, each with its own store, credentials, sessions and Lean rules. A
   default never couples two installs; a broken install configuration fails
   closed instead of falling back to another install's state.

## 2. Install layout

```
<prefix>/
├── bin/metacodes[.exe], bin/rg[.exe]
├── libexec/metacodes/
│   ├── metacodes-formal-kernel[.exe]   + .provenance.json + .build-receipt.json
│   └── metacodes-project-kernel[.exe]  + .provenance.json
├── vendor/tinykg/tinykg[.exe], tinykgd[.exe]  + .provenance.json each
├── sdk/agentcore/                      the AgentCore bundle as built by
│                                       `agentcore:bundle` (include/metask/agentcore.h,
│                                       lib/, bindings/zig, bindings/rust, manifest)
├── share/licenses/, share/doc/
├── etc/metacodes/install.json          written by the installer only
└── state/                              default state root, created by the installer
```

The release archive is this tree without `etc/` and `state/`. Kernel digests
are pinned into `bin/metacodes` at build time (`-Dformal-kernel-sha256`,
`-Dproject-kernel-sha256`), so `doctor --strict` proves every runtime asset
beside the executable is the one this build was made with.

## 3. State root

Resolution policy (host layer only, `src/util/state_root.zig`, pure
`resolveFrom`), first match wins:

1. `--state-dir <dir>` (argv[1] to also cover subcommands);
2. `METACODES_HOME`;
3. `<prefix>/etc/metacodes/install.json` beside the physical executable:
   `{"schema_version":"metacodes-install-v1","version":"…","state_root":"state"}`,
   a relative root being relative to `<prefix>` so the whole install can move;
4. `$HOME/.metacodes` (development builds; installs predating this design).

A present but invalid `install.json`, or a relative override, stops the CLI.

Everything that used to live under `~/.metacodes` lives under the root with
the same relative names (`config.json`, `auth.json`, `oauth/`, `kg/`,
`projects/`, `teams/`, `plans/`, `worktrees/`, `history`, `pastes/`,
`models.toml`, `context_caps.json`, `ledger/`, `agents/`, `CLAUDE.md`,
`AGENTS.md`, `skills/`, `research/`). Project-scoped `<project>/.metacodes/` and
the user's `~/.claude/` are unchanged. The more specific overrides
(`METACODES_CONFIG_FILE`, `METACODES_AUTH_FILE`, `METACODES_KG_STORE`, …) still
win over the root.

Core receives the root explicitly: the CLI resolves it once and hands it to
`App`; `App` passes it to `ToolContext.state_root`, the swarm context, the KG
client and every subsystem constructor. No `src/lib.zig` module reads the
process-global resolution.

## 4. Installer

`bin/metacodes install --prefix <dir> [--state-dir <dir>] [--force]`, run from
an extracted release bundle (or from a `release:stage` tree built from source):

1. refuses a prefix holding a different install unless `--force`, and never
   writes outside `<prefix>` and the chosen state root;
2. copies the bundle tree it runs from into `<prefix>`;
3. writes `etc/metacodes/install.json` and creates the state root (0700);
4. runs the installed `bin/metacodes doctor --strict` and reports.

`install.sh` (macOS/Linux) and `install.ps1` (Windows) only locate or extract
the bundle and invoke step 1–4, so the install logic exists once, in Zig.

## 5. Kernels in release builds

Each release job installs the pinned elan (`scripts/ci/install-elan.sh`; the
Windows job its PowerShell equivalent), builds both kernels natively with
their scripts (axiom audit, native smoke, provenance), and builds the
executable with the kernel digests pinned. `release/LAYOUT.md`,
`release/manifest.schema.json` and `scripts/verify_install_prefix.py` list the
kernels and `tinykgd` as required runtime assets.

## 6. Tests

`zig build test` builds both kernels from the checkout (`kernels:stage`,
`-Dlean-kernels=auto|on|off`) into the build's own prefix and hands them to
kernel-gated tests through `METACODES_TEST_<KIND>_KERNEL_PATH`; the digest
comes from the provenance sidecar (`src/formal/test_kernel.zig`). CI runs with
`-Dlean-kernels=on` wherever elan is provisioned, so the gate cannot silently
degrade to skips.
