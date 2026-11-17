# Agent sandbox execution boundaries

The controller (AgentLoop, model connection, permissions, budget and audit)
stays on the host. Native metacodes tools execute filesystem operations and
commands through a sandbox executor. External harness workers run as a whole
process tree inside the same platform boundary.

```text
host controller
  +-- metacodes worker
  |     +-- Read / Write / Edit -> confined filesystem helper -> exact fd
  |     +-- Grep / Glob / Bash -> confined command and its children
  +-- external harness -> confined harness and its children
```

## Platform backends

On Linux, bubblewrap builds the filesystem/namespace view; seccomp restricts
system calls inside that view. Writable mounts reopen the workspace,
explicit additional directories and temporary directories over a read-only
root. Read and write denials are applied over those grants. Seccomp prevents
the blocked syscall families from being recovered through a subprocess or
a new executable. The Linux filter is installed in the confined child, never
on the controller thread. macOS uses a generated Seatbelt profile for the
same execution boundaries.

The reviewed Linux syscall ABIs are x86_64 and aarch64. A mismatched audit
architecture or x32 ABI cannot enter the native allow path. The filter blocks
io_uring, cross-process memory/ptrace access, namespace/mount manipulation and
other privileged kernel interfaces. Shared networking permits ordinary IPv4
and IPv6 sockets, not named Unix sockets or VM sockets. Connected Unix
stream/seqpacket socketpairs remain available for descendants and inherited
helper IPC; datagram pairs cannot be used to retarget a host Unix listener.
The BPF program travels over an anonymous pipe to bubblewrap's `--seccomp`
descriptor, with no mutable filter file or parent-owned fd to survive a
background launch. This is syscall hardening, not a container or VM boundary.

Sandbox configuration is not a permission grant: the existing tool permission,
execution-policy, formal verdict and budget checks still run before execution.
An explicit host opt-out is different from a missing sandbox. Native file tools
and external workers refuse the operation when their enabled sandbox cannot
be constructed. They have no excluded-command escape hatch.

The network policy currently has no domain-filtering proxy. Linux isolates
the network namespace if either domain list is populated; with neither list
it shares the host network while retaining seccomp hardening. Seatbelt's
current profile does not implement domain filtering. These are not equivalent
network policies; a domain list is not a working allowlist on both platforms.

## Native filesystem operations

`src/sandbox/filesystem.zig` routes enabled native file access through
`metacodes-fs-helper`. The helper is built from
`src/sandbox_helper_root.zig` and installed in `bin/` for both the CLI and the
AgentCore bundle. Build it with `zig build sandbox:helper`.

The helper opens the target and, for Write, creates missing parent directories
inside the OS sandbox. A bounded private Unix-socket protocol carries the
path, access flags, mode and parent-creation request. SCM_RIGHTS returns the
opened descriptor. The controller uses that descriptor for existing ReadState,
exact-edit checks and file-change receipts rather than reopening its pathname.
The protocol is private implementation detail, not an AgentCore ABI extension.

The trusted Host may set `METACODES_SANDBOX_HELPER` to an absolute executable
path. Otherwise the executor resolves the helper beside its own physical
executable. There is no PATH search or project setting for this executable.
An embedded Host must deploy the helper beside itself or supply that absolute
override; the bundle manifest inventories the helper and its digest.

Read (including images), Write, Edit and the Grep/Glob command execution use
this boundary when sandboxing is enabled; NotebookEdit uses it too. The Read outline optimization must
not dispatch to an unconstrained LSP instead of the confined file read.
Filesystem helper requests cannot turn off sandboxing or select a different
policy. The policy is assembled by the controller before launching the helper.

## External harness workers

`src/sandbox/worker.zig` prepares a whole-process launch for arbitrary argv.
The Claude Code seat driver uses it for `--version`, `--help` and the actual
worker invocation. Each argument is quoted independently, and the enabled
sandbox must produce a confined launch. A missing or unusable backend stops
the seat before a compatibility probe runs.

The worker inherits the Host's read/write denials and network lists, not its
extra writable grants. Claude Code receives writable access to its workspace,
seat directory, temporary roots and its configured default state locations.
The factory forwards the same Host sandbox to either harness. Only the
trusted runtime's explicit `Options.sandbox=false` opts out; backend discovery
never selects that path implicitly.

## Validation

Tests execute real confined commands with no paid provider calls. They cover
allowed workspace reads/writes, denied and symlinked targets, native tool
results and mutation receipts, forbidden syscalls and inheritance, and the
external harness's probes and child processes. A fake harness records which
stages ran, so failure before launch cannot masquerade as successful isolation.
Linux behavior is exercised on the Linux devbox; macOS execution requires a
macOS runner, and Windows has no equivalent OS sandbox backend here.
