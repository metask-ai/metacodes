# Installation, per-install state, and bundled governance kernels

Status: implemented. Owner of the decisions below: the maintainer; this
document records them so the implementation and reviews have one source.

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

A present but invalid `install.json`, or a relative override, stops the CLI
(`doctor` still runs and reports it). A root that cannot be created (a
read-only or missing home) only warns: each subsystem degrades as it did
without `$HOME`. The resolved root carries no trailing separator.

The record names one root for everyone who runs that install. A system-wide
install (`--prefix /opt/metacodes` by root) therefore needs `--state-dir` (or
each user's `METACODES_HOME`): its default `<prefix>/state` is created 0700
for the installing user. A process teammate receives the lead's root as its
leading `--state-dir`.

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

`bin/metacodes install --prefix <dir> [--state-dir <dir>] [--sdk <bundle>]
[--link <dir> [--link-name <name>]] [--upgrade] [--force]` (src/app/install.zig),
run from an extracted release unit or one staged from source (`release:verify`):

1. refuses a prefix that holds anything but this product's install unless
   `--force`, and another version of it unless `--upgrade` (or `--force`);
   refuses a bad `--sdk` bundle and a taken launcher name (step 5) before it
   writes anything; writes only under `<prefix>`, the state root and the
   `--link` directory;
2. writes `etc/metacodes/install.json` (`"state_root": "state"`, or the
   absolute `--state-dir`) and creates the state root (0700), first, so a copy
   that fails half way can be retried without `--force`;
3. copies every file the unit's `manifest.json` lists and re-hashes it at the
   destination (a damaged unit fails on the first mismatch); when it replaces
   another version, removes the files the old manifest listed and the new one
   does not. The state root is never touched;
4. with `--sdk`, replaces `<prefix>/sdk/agentcore/` with the AgentCore bundle,
   each file verified against that bundle's manifest;
5. with `--link`, writes a launcher script (POSIX `sh`, Windows `.cmd`) that
   `exec`s the installed executable. The name must be free or hold this
   install's own launcher; a symlink is never written through, and anything
   else needs `--force`;
6. runs the installed `bin/metacodes doctor --strict` in an empty environment
   (POSIX) and requires every runtime asset adjacent and the state root to come
   from the install record.

`scripts/install.sh` (macOS/Linux; default prefix `~/.local/opt/metacodes`,
launcher in `~/.local/bin`) and `scripts/install.ps1` (Windows; default prefix
`%LOCALAPPDATA%\Programs\metacodes`, `<prefix>\bin` added to the user PATH
unless `-NoPath`) only obtain a unit, check its digests, unpack it, and call
steps 1–6 with `--upgrade`, so the install logic exists once, in Zig and a
rerun upgrades. CI runs both scripts on the verified release unit, and
release.yml on the archives it publishes.

`install.sh` obtains the unit one of three ways:

- **a published release** (no argument; `curl -fsSL
  https://raw.githubusercontent.com/metask-ai/metacodes/main/scripts/install.sh | sh`):
  the latest tag (the `/releases/latest` redirect, no API call) or
  `--version`, the host's archive (`aarch64-macos`, `x86_64-linux-gnu`) and the
  matching AgentCore SDK archive, each checked against the release's
  `metacodes-<tag>-SHA256SUMS`. `--release-base` names a mirror with the same
  `download/<tag>/<asset>` layout. A unit whose manifest is not schema 2 (a
  release before the installer) is refused rather than executed: its
  executable would read `install` as a prompt;
- **a checkout** (`--dev`, or `--source <dir>` when piped): kernels,
  `kernel_pins.py`, `release:verify` and `agentcore:archive`, ReleaseSafe as
  release.yml builds them, into `<checkout>/zig-out/dev-unit`. The install is
  named after the checkout: the main checkout is `metacodes-dev`, a linked
  git worktree `metacodes-dev-<worktree directory>`, so testing a worktree
  never replaces the main checkout's install. The default prefix is
  `~/.local/opt/<launcher name>` in every mode;
- **an archive or unit directory** named on the command line.

A released install and development installs therefore coexist by default,
with separate prefixes, launchers and state roots. An install is a copy of the
unit, each file replaced atomically, so rebuilding, switching branches or
removing a worktree never disturbs a running install, and an upgrade does not
break a session that is still running the old executable.

`install.sh --uninstall` (with the same `--dev`/`--prefix`/`--link-name`
selection) removes an install: only a prefix holding this product's install
record, never while a process runs from it, together with its launcher when
that launcher is this install's own. A state root inside the prefix goes with
it; an outside `--state-dir` root is kept. Neither imports an existing
`~/.metacodes`; when one exists and the new root is empty, the script says how
to reuse it (`--state-dir ~/.metacodes`, or copying `config.json`, `auth.json`
and `models.toml`).

## 5. Kernels in release builds

Each release job installs the pinned elan (`scripts/ci/install-elan.sh`, under
Git Bash on Windows), builds both kernels natively with their scripts (axiom
audit, native smoke, `check_kernel_self_contained.py`, provenance), and builds
the executable with the kernel digests pinned (`scripts/kernel_pins.py`). The
kernels link the Lean runtime, GMP and libuv statically; their licence texts
ship under `share/licenses/` (vendor/lean-runtime/). aarch64-linux stays a
cross-staged asset check until a native aarch64 runner can build its kernels. `release/LAYOUT.md`,
`release/manifest.schema.json` and `scripts/verify_install_prefix.py` list the
kernels and `tinykgd` as required runtime assets.

## 6. Tests

`zig build test` builds both kernels from the checkout (`kernels:stage`,
`-Dlean-kernels=auto|on|off`) into the build's own prefix and hands them to
kernel-gated tests through `METACODES_TEST_<KIND>_KERNEL_PATH`; the digest
comes from the provenance sidecar (`src/formal/test_kernel.zig`). CI runs with
`-Dlean-kernels=on` wherever elan is provisioned, so the gate cannot silently
degrade to skips.
