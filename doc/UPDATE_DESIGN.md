# `metacodes update`: bring an install up to date from where it came from

Status: implemented 2026-10-25 (§12 records the decisions). Code:
`apps/cli/src/app/update.zig`, `apps/cli/src/app/release_fetch.zig`, `apps/cli/src/app/unit_archive.zig`,
`apps/cli/src/app/release_source.zig`, `src/platform/process_scan.zig`. Builds on [INSTALL_DESIGN.md](INSTALL_DESIGN.md) §4 (the installer
and `install.sh`) and [RELEASE_AUTOMATION_DESIGN.md](RELEASE_AUTOMATION_DESIGN.md)
(what a published release contains).

## 1. Goals and non-goals

Goals:

- One command, run from an installed executable, brings *that* install up to
  date from the source it was installed from, on every release platform
  (macOS, Linux, Windows):
  - a **release install** moves to the newest published stable release, or a
    named one. It uses the mirror the install came from, if it came from one;
  - a **development install** is rebuilt from the checkout it was built from.
- The prefix, the state root, the launcher and the SDK, if one is installed,
  all stay as they are.
- Nothing new is trusted, and no install logic is written a second time. A
  release is checked the way `install.sh` checks it, and a checkout is built
  by `install.sh --dev`. Both are installed by the same `metacodes install`
  code.
- Rerunning converges. Whatever an interrupted or failed run left behind, the
  next `metacodes update` repairs it.
- An install never moves backwards unless the user asks, never touches
  another install, and writes only under its own prefix. The single exception
  is the TinyKG daemon pin in its own state root (§6.3).

Non-goals:

- **Automatic updates.** Nothing is installed unless the user runs `update`
  or picks it at the interactive notice (§13). Only the interactive TUI checks
  for a newer release; `-p`, `serve`, `--web`, evaluation runs and
  provider-visible bytes stay as they are.
- **Replacing the prefix in one transaction.** The installer copies file by
  file. Update makes up for this by converging (§8).
- **Signature verification.** Releases carry SHA-256 sums and no signature
  yet; provenance attestation is a scheduled follow-up
  (RELEASE_AUTOMATION_DESIGN.md §7). When it lands, update verifies it before
  §4.2 step 6.
- **Building a development install on Windows.** There is no from-source
  installer there (`install.sh --dev` is POSIX, and the kernel builds are
  shell scripts), so a Windows install records no checkout and update says
  why (§4.3).

## 2. Command surface

```
metacodes [--state-dir DIR] update [--check] [--version X.Y.Z]
          [--release-base URL] [--pull] [--allow-downgrade] [--no-sdk]
          [--ignore-running] [--json]
```

| Option | Meaning |
|---|---|
| (none) | release install: the release `<base>/latest` redirects to. Development install: rebuild the checkout as it is |
| `--check` | report what would happen and change nothing. When an update or repair is available it also lists the sessions that would refuse it and the TinyKG service a real run would stop (§4.1 step 4). Exit 0 when there is nothing to do, 3 when an update or repair is available, sessions or not |
| `--version X.Y.Z` | release install only: that published release instead of the latest |
| `--release-base URL` | release install only: a mirror of `https://github.com/metask-ai/metacodes/releases` with the same `latest` and `download/<tag>/<asset>` layout. It is recorded, so later updates use it too (§3) |
| `--pull` | development install only: `git pull --ff-only` in the checkout first |
| `--allow-downgrade` | let `--version` name an older release, or a checkout carry an older version, than the one installed |
| `--no-sdk` | do not refresh the AgentCore SDK even though the install has one; the installed SDK stays |
| `--ignore-running` | update while sessions run from this install (§6). Refused on Windows |
| `--json` | one result document on stdout: `{action, source, from, to, prefix, origin, sdk, checked_only, stopped_services[], running_sessions[], sessions[], services[], notes[]}`; a failure prints `{action: "refused", error}`. `stopped_services` and `running_sessions` are what a real run did: the service pids it stopped and the sessions it left running (`--ignore-running`); they are always empty under `--check`. `sessions` and `services` are what `--check` found: the session pids that would refuse the update and the service pids a real run would stop; they are always empty without `--check` |

`action` is one of `up_to_date`, `newer_installed`, `upgrade`, `downgrade`,
`repair`, `rebuild` or `refused`. `source` is `release` or `checkout`. `origin`
is the release base or the checkout used.

An option that does not apply to the install's source is a usage error, not
something to ignore: `--pull` on a release install, or `--version` or
`--release-base` on a development install. So is `--check --pull`: `--check`
changes nothing, and a pull changes the checkout.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | done, or nothing to do |
| 1 | refused or failed |
| 2 | usage error |
| 3 | `--check` only: an update or repair is available |

The surface is fail-closed like every other subcommand: an unknown argument
exits 2 and names itself. `update` joins the subcommand list in
`apps/cli/src/main.zig` (`maybeRunAuthCommand`). Like `install`, it runs before the
process resolves its own state root, so a broken state root does not stop a
repair.

## 3. Where an install updates from: the install record

`etc/metacodes/install.json` (schema `metacodes-install-v1`) gains one
optional member that says where the install came from:

```json
{
  "schema_version": "metacodes-install-v1",
  "version": "0.8.0",
  "state_root": "state",
  "update_source": { "kind": "release", "base": "https://mirror.example/metacodes/releases" }
}
```

or `{"kind": "checkout", "path": "/home/me/src/metacodes"}`.

- **One tagged member, not two optional ones**, so "a release base and a
  checkout" cannot be represented. Every reader of `install.json`
  (`util/state_root.zig`, `install.zig`, `install.sh`, `install.ps1`) already
  ignores unknown members or reads its own keys line by line, so the schema
  stays `metacodes-install-v1`.
- **Who writes it.** The installer, from two new options:
  - `metacodes install --release-base URL` records a release source. The
    default GitHub base is not recorded: a missing member means "the
    default". Passing the default URL therefore clears a mirror.
  - `metacodes install --checkout DIR` records a checkout source.
  - Giving both is a usage error.
- **Neither option given** (an archive installed by hand, or `install.ps1`
  without `-ReleaseBase`): the installer keeps the previous record's source,
  as it already keeps the recorded state root. A fresh install gets none.
- **The source is not tied to the channel.** A clean checkout at a release tag
  builds a `stable` unit (release/LAYOUT.md), so `install.sh --dev` can pass
  `--checkout` with a stable unit. And an archive installed by hand over a
  development prefix keeps updating from the checkout, which is the prefix's
  source.
- **A malformed member never costs the state root.** `update_source` is
  parsed apart from the rest of the record. A member that is not a valid
  source is dropped with a note by the installer, and refused by `update`
  (`InvalidUpdateSource`).
- **Validation**, done by the installer (the installer of the unit being
  installed is what writes the record) and again by `update` before using
  the value:
  - A base is an absolute `https://` URL, or `http://` to a loopback host,
    with no user-info, query or fragment. A credential in a recorded URL
    would leak into every request and, across a redirect, into another host
    (Zig 0.16 forwards request headers on redirect). A trailing `/` is
    dropped.
  - A checkout is an absolute path.
- **Who passes them.**
  - `install.sh` passes `--release-base <the base it downloaded from>` for a
    published release, and `--checkout <checkout>` with `--dev`.
  - `install.ps1 -ReleaseBase URL` passes it through. That script installs
    an archive and downloads nothing, so the user names the mirror the
    archive came from.
  - `update` passes `--release-base <the base it used>` to the release it
    installs, so the record always names the source of the version it holds.
  - Every caller probes the unit's `install --help` first and passes an
    option only to a unit that names it, as `install.sh` already does for
    `--allow-downgrade`. Units up to 0.7.0 know neither option.
- **Precedence in `update`:** `--release-base` > the record's release
  source > the default base.

## 4. Flow

### 4.1 Common steps

0. **Parse** the options (§2).
1. **Locate the install** from the physical executable (`selfExeRealPath` →
   `state_root.prefixOf`). Read `<prefix>/etc/metacodes/install.json` (with
   `update_source`) and `<prefix>/manifest.json` (`metacodes-cli`, schema 2:
   `release.version`, `release.channel`, `source.commit`, `source.dirty`,
   `target.id`). Refusals, all before any network or checkout access:
   - **No install record.** This is an unpacked unit or a build output, not
     an install. Point to `install.sh` or `metacodes install --prefix`.
   - **An invalid `update_source`** (§3).
   - **Channel `pre` without a recorded source** (a development install
     from before §3, or one installed by hand). Point to
     `scripts/install.sh --dev` in its checkout once; after that, update
     knows the checkout. `--release-base` overrides this, for a user who
     wants a release there.
   - **A development source on Windows** (§1).

   The asset to fetch is named by the installed manifest's `target.id` (the
   executable that runs `update` was built for it). Without a readable
   manifest, the id of the platform the executable was built for is used.
2. **Lock** `<prefix>/.update/lock` with the operating system's exclusive
   advisory lock (`flock`, `LockFileEx`), taken without waiting: a second
   update of the same prefix stops with `UpdateInProgress`, and a crashed run
   releases the lock as it exits. `util/file_lock.zig` does not fit here: it
   treats a lock older than 10 s as abandoned, and a development rebuild holds
   this one for minutes. Under the lock, remove `<prefix>/.update/run-*` left
   by runs that crashed, and (Windows) executables renamed aside by earlier
   runs that have exited.
3. **Measure the install.** It is `intact` when the record version equals
   the manifest version, every file the manifest lists is present with its
   digest, and so is every file of `sdk/agentcore/manifest.json` when that
   exists (§8). Keep the old manifest's TinyKG digests for §6.3.
4. **Plan** per source (§4.2, §4.3). `--check` reports the plan here and
   stops. When the plan changes the install, it first runs step 5's scan and
   reports what it found without acting on it: the sessions, listed as a
   real run lists them, with "the update would be refused until they exit"
   (POSIX adds "or with --ignore-running"; with `--ignore-running` it says
   a real run goes ahead), and the TinyKG service pids a real run would
   stop. It refuses nothing and signals nothing, and the exit code stays 3.
   The scan is best effort, as in the real run; if it fails, a note says so
   and the real run would stop with `ProcessScanFailed`.
5. **Check running processes** (§6). Sessions refuse unless
   `--ignore-running`: once before any download, so a refusal costs nothing,
   and again after this install's TinyKG service has been stopped, which
   happens only once everything is downloaded and verified.
6. **Install** per source (§4.2, §4.3). The installer ends with
   `doctor --strict` on the result.
7. **Refresh the TinyKG pin** if the TinyKG binaries changed (§6.3).
8. **Clean up and report.** Remove the run's staging directory. Print
   `metacodes <from> → <to>` and the path of
   `<prefix>/share/doc/CHANGELOG-<to>.md`. If sessions were left running,
   say that they must be restarted.

### 4.2 A release install

1. **Base** by the precedence in §3.
2. **Tag.** With `--version`, use it. Otherwise GET `<base>/latest`
   without following the redirect and take the tag from
   `Location: …/tag/<tag>`. This is the same request `install.sh` makes: it
   is not the API and has no rate limit. The tag must be a bare stable
   `X.Y.Z`, the only form `release.yml` publishes. Drafts and pre-releases
   are never `latest`.
3. **Plan.** `planRelease(installed, intact, target, explicit,
   allow_downgrade)` is a pure function with a table test:

   | target vs installed | intact | `--version` | action |
   |---|---|---|---|
   | same | yes | any | `up_to_date`: no asset is downloaded |
   | same | no | any | `repair`: reinstall that version |
   | newer | any | any | `upgrade` |
   | older | yes | no | `newer_installed`: GitHub's Latest label can point at an older maintenance release (RELEASE_AUTOMATION_DESIGN.md §4); nothing is done, exit 0 |
   | older | no | no | `repair`: reinstall the *installed* version (the tag becomes that version), never the older latest |
   | older | any | yes | `refused` without `--allow-downgrade`, else `downgrade` |

   For an install that is not intact, "installed" means the higher of the
   record version and the manifest version, so a half-finished upgrade is
   completed, never undone. The order is `install.zig` `isOlder`, made
   public. Update does not get a fourth implementation of semver order.
4. **Fetch `metacodes-<tag>-SHA256SUMS`** (at most 64 KiB). Parse it
   strictly: `<64 lowercase hex>  <name>` lines, no duplicate names. Select:
   - the CLI asset `metacodes-<tag>-<target.id>.tar.gz` (`.zip` on Windows),
     which is required;
   - the SDK asset, only if `<prefix>/sdk/agentcore/manifest.json` exists and
     `--no-sdk` is absent: exactly one `metask-agentcore-*-<target.id>.<ext>`
     entry. If there is none, warn and keep the installed SDK (the installer
     replaces the SDK only when it is given `--sdk`). More than one is
     refused as ambiguous.
5. **Download** each asset into the run's staging directory. Hash it with
   SHA-256 while it streams. Bytes and time are capped (§5). On a mismatch,
   delete it and refuse; nothing has been unpacked or run.
6. **Unpack** with a restricted extractor, not `std.tar.extract`. That
   function creates symlink entries with any target, so a symlink `a → /x`
   followed by a file `a/y` would write outside the staging directory. Only
   regular files and directories are accepted. Symlinks, hard links,
   devices, absolute paths, drive letters, `..`, backslashes in a tar
   member, duplicate entries, and anything outside the single
   `metacodes-<tag>-<target>/` root are refused. Entry count and total size
   are capped. On POSIX the executable bit comes from the entry's mode.
   Zip archives go through the same rules, built on `std.zip`.
7. **Verify the staged unit before running any of it.** The manifest must be
   `metacodes-cli` schema 2, `release.version == tag`,
   `release.channel == "stable"` and `target.id` equal to the installed one,
   and every listed file must match its digest. The installer verifies again
   at the destination. The SDK bundle is checked the same way against its
   own manifest.
8. **Delegate** to the staged unit's installer:
   `<unit>/bin/metacodes install --prefix <prefix> --upgrade [--sdk <bundle>]
   [--release-base <base>] [--allow-downgrade]`, with stdin closed, output
   relayed, and the environment inherited.
   - **No `--state-dir`:** the installer keeps the recorded root
     (`install.zig` `previousStateRoot`).
   - **No `--link`:** the launcher execs `<prefix>/bin/metacodes`, and that
     path does not change.
   - **Never `--force`.**
   - **`--allow-downgrade` and `--release-base`** go only to a unit whose
     `install --help` names them. Units up to 0.5.0 know neither and do not
     check the order, but update has already decided the order itself.

### 4.3 A development install

1. **Checkout.** Take `update_source.path`. It must still be a metacodes
   checkout, by the same tests `install.sh --dev` makes (`build.zig`,
   `release/manifest_contract.zig`, `scripts/kernel_pins.py`,
   `scripts/install.sh`). A removed worktree is refused with the path it had.
   On Windows this step is refused: no from-source installer exists there.
2. **`--pull`:** `git -C <checkout> pull --ff-only`, and stop if it fails.
   Update never merges, rebases or stashes the user's work.
3. **Plan.** `planCheckout(installed, intact, head, allow_downgrade)` is a
   pure function with a table test. `head` is `git rev-parse HEAD`, whether
   the tree is dirty (`git status --porcelain`), and the checkout's
   `build.zig.zon` version:

   | checkout vs install | intact | action |
   |---|---|---|
   | same commit, both clean | yes | `up_to_date`: no build |
   | same commit, both clean | no | `repair` (a rebuild) |
   | another commit, or either side dirty | any | `rebuild` |
   | checkout version older than installed | any | `refused` without `--allow-downgrade` (a checkout switched to an old branch) |

   A dirty tree always rebuilds, because update cannot know what changed.
4. **Delegate** to the checkout's own installer:
   `sh <checkout>/scripts/install.sh --dev --source <checkout> --prefix
   <prefix> --no-link [--no-sdk] [--allow-downgrade]`, with stdin closed,
   output relayed, and the environment inherited (it needs `zig`, `python3`
   and `elan` on `PATH`, as `--dev` always has).
   - **`--no-link`:** the launcher stays as it is.
   - **`--no-sdk`:** only when the install has no SDK, or `--no-sdk` was
     given.
   - The script builds the unit the way `release.yml` does and installs it
     with `--checkout`, so the record keeps naming the checkout.

### Why the source installs itself

The installer of the version being installed is the one that knows its
layout: which files its manifest adds or drops, and which record fields it
writes. An old executable copying a newer unit would apply old rules to it.
A checkout likewise knows how to build itself, and its `install.sh` is the
build recipe of that commit. `install.sh` already splits the work this way
("the install logic exists once"), and update orchestrates those steps from
Zig.

The cost is a cross-version contract. Every future release must accept
`install --prefix --upgrade --sdk --allow-downgrade --release-base
--checkout` with today's meaning, and every future `install.sh` must accept
`--dev --source --prefix --no-link --no-sdk --allow-downgrade`.
`tests/component/update_test.zig` asserts the first list against
`install --help`, and `scripts/tests/test_install_scripts.py` asserts the
second. The installer documentation names the contract, so removing a flag
is a visible break.

## 5. Network

Every transfer is a `curl` run (`apps/cli/src/app/release_fetch.zig`), as in
`install.sh`. So proxies (`https_proxy`, `all_proxy`, SOCKS, `NO_PROXY`),
retries and timeouts behave the same for both. On Windows, `curl.exe` ships
with Windows 10 1803 and later. Without curl on PATH, update stops with
`CurlUnavailable`.

**Why not `std.http.Client`.** The first implementation used it, and the real
binary failed against GitHub on a machine with `HTTPS_PROXY` set: the
connection closed before a byte of the response (`HttpConnectionClosing`).
The same request without the proxy worked. Zig 0.16's `connectProxied`
opens the proxy's CONNECT tunnel and returns it as a plain connection: the
request then goes through the tunnel without a TLS handshake. std also has no
connect timeout (`ConnectTcpOptions.timeout` is declared but never passed
on), which had forced a watchdog that ended the process on a stall.

What update asks of curl, in `Fetcher.baseArgs`:

- **`-q` first**, so `~/.curlrc` cannot add options. An `insecure` line there
  would turn TLS checks off.
- **`--proto` and `--proto-redir`** set to `=https`. A loopback base (the
  tests, a local mirror) gets `=http,https` and `--noproxy '*'`.
- **No credential, cookie or netrc** is ever passed.
- **Timeouts:** `--connect-timeout 30` and `--speed-limit 1 --speed-time
  60`, so a transfer that moves no byte for 60 s stops with exit 28.
- **`--retry 3`** and **`-f`**: an HTTP error status is a failure.
- **Size limits:** `--max-filesize` with 64 KiB for SHA256SUMS and 512 MiB per
  archive (the largest 0.6.0 archive is 21 MB), and the size is checked again
  afterwards.
- **`latest`** is read the way `install.sh` reads it: `-L -I -w
  '%{url_effective}'`, then `…/tag/<X.Y.Z>`.
- **Progress:** curl's progress bar at a terminal, and its error message
  otherwise.

curl's exit status is mapped to `ConnectFailed` (resolve, connect, proxy,
TLS, certificate), `HttpStatus` (22), `TooLarge` (63), `InvalidUrl` (a
refused protocol) or `TransferFailed`. Every byte that matters is checked by
update itself, not by curl: the archive against the sums, then every file
against the unit's manifest.

**Trust.** TLS to GitHub → SHA256SUMS → archive digest → unit manifest →
each file's digest. This is exactly what `install.sh` trusts. A mirror serves
both the sums and the archives, so using one means trusting the mirror
completely, and recording it (§3) makes that trust last. The help text and
the install summary both name the base in use.

## 6. Processes running from the prefix

### 6.1 What a swap does to an old process (from the code, 2026-10-25)

The installer replaces each file by atomic rename (`Dir.copyFile` →
`createFileAtomic` → `replace`). On POSIX a running process keeps its old
inode, but it reaches the runtime assets again by path:

| Asset | When it is checked | An old session after the swap |
|---|---|---|
| `bin/metacodes` | — | keeps running the old image |
| formal kernel | hashed against the compiled pin on **every** invocation (`src/formal/runtime.zig:324`) | next formal check fails closed: `checker_hash_mismatch` |
| project kernel | hashed on every invocation; an active rule bundle re-attests it **every turn** (`src/core/project_rule_bundle.zig:489`) | the next turn is refused: "The project rules refused to start this turn" (`apps/cli/src/repl/loop.zig:985`) |
| tinykg CLI, rg | path resolved once, not hash-checked | silently runs the new binary |
| kgd + tinykgd | hashed once, at service start | keeps serving the old binaries |

So `doc/INSTALL_DESIGN.md` §4 overstates the case when it says an upgrade
"does not break a session that is still running the old executable". That
holds for the executable, not for the kernels. The same change corrects the
sentence. On Windows none of these files can be replaced while a process
has them open.

### 6.2 Policy

- **Scan.** `src/platform/process_scan.zig` lists processes whose physical
  executable is under `<prefix>/`, each with its parent pid:

  | Platform | Process list | Executable path | Parent pid |
  |---|---|---|---|
  | macOS | `proc_listallpids` | `proc_pidpath` | `proc_pidinfo(PROC_PIDTBSDINFO)` |
  | Linux | `/proc` | `/proc/<pid>/exe` (stripping the ` (deleted)` suffix a replaced binary shows) | `/proc/<pid>/stat` |
  | Windows | `CreateToolhelp32Snapshot` (gives the parent pid) | `QueryFullProcessImageNameW` | — |

  Matching the executable path is exact; `install.sh --uninstall` matches
  `ps` command lines instead. The update process itself is excluded.
  Processes of other users may be invisible; the scan is best effort.
- **Classes.** A process is this install's **TinyKG service** if it is
  `vendor/tinykg/tinykgd` from the prefix, or a `bin/metacodes` from the
  prefix that is the parent of one. Everything else from the prefix is a
  **session**: the REPLs and headless runs, and the kernels, rg and tinykg
  CLI they spawn. Classifying by parentage needs no access to another
  process's argv. A kgd that has not spawned its tinykgd yet counts as a
  session, which errs on the safe side.
- **Sessions:** refuse, listing each pid and executable, and suggest
  exiting them or passing `--ignore-running` (POSIX only). With that flag
  the update goes ahead, and §4.1 step 8 reminds the user to restart them.
- **The TinyKG service:** stop it, then wait up to 10 s for both of its
  processes to exit, and refuse if either is still alive.
  - POSIX: SIGTERM to the kgd process. Its supervisor handles that by taking
    tinykgd down cleanly (`src/kg/kgd/runtime.zig:177-180`).
  - Windows: kgd runs windowless, so no console control event reaches it.
    It is ended with `TerminateProcess`, and tinykgd follows on its own when
    its stdin closes. That the real tinykgd exits on stdin EOF was observed on
    macOS (exit 0) and is inferred for Windows (same program). The L2 test
    runs the same parent/child arrangement on every platform with a
    stand-in whose child exits on EOF.
  - Before each signal the pid's executable is read again, so a pid reused
    since the scan is never signalled. Waiting treats a zombie as gone:
    Linux reads the state from `/proc/<pid>/stat`, and macOS takes ESRCH
    from `proc_pidinfo`, which fails for a zombie while `kill(pid, 0)` still
    succeeds (observed on macOS 26).

  The next session autostarts the new service. If sessions were ignored,
  they lose the KG for the rest of their run; they have to be restarted
  anyway.
- **Races.** A session that starts between the scan and the swap is not
  caught on POSIX. On Windows it makes a copy fail, and that is covered by
  §8. A session-side lock would cost every session start and is not worth
  it.

### 6.3 The TinyKG pin

A session trusts the service whose `expected_build_id` sits in
`<state>/kg/daemon.json`. The id is a hash over the tinykg and tinykgd
binaries, among other inputs (`src/kg/kgd/identity.zig`). The installer never
rewrites it.

Once a release changes the TinyKG bundle, the restarted service reports a new
id, and every session's transport refuses it. Before 2026-10-25, a session
then reported `pin_mismatch`, fell back to the `tasks.json` mirror, and
nothing recovered it: autostart provisioned only a missing file and accepted
any listener that answered with the key. It had not happened yet because the
bundle has not changed since 0.2.0 (`bb8284ab`), and a rerun of `install.sh`
had the same latent problem.

Two repairs now cover it, and they write the same value:

1. **Update.** After a successful install, update runs the new
   `<prefix>/bin/metacodes [--state-dir DIR] kg install` when the old and new
   manifests list different digests for `vendor/tinykg/tinykg` or `tinykgd`,
   and the default `daemon.json` exists. That rewrites the id and keeps the
   API key. A custom `METACODES_KG_CONFIG` or `METACODES_KG_*` environment is
   left alone with a note.
2. **Autostart**, for every way the binaries can change (an update, a rerun
   of `install.sh`, a hand install). The transport reports the case as its
   own error, `BuildMismatch`. Autostart pins the installed binaries' id
   before it starts a service, and repins this install's running service
   when a session reports `stale_pin`. A session that holds the old pin
   re-reads the file on its next probe. The full rule is
   doc/TINYKG_INTEGRATION.md, "A stale pin"; the L2 tests are the three
   "stale pin" tests in `tests/component/kgd_e2e_test.zig`.

## 7. Windows

- **The running executable.** A running `.exe` cannot be overwritten, but
  it can be renamed. Before delegating, update renames
  `<prefix>\bin\metacodes.exe` to `metacodes.exe.<pid>.old`. If the install
  fails before a new `metacodes.exe` exists, it renames it back. Leftover
  `*.old` files are deleted by the next update; the delete fails harmlessly
  while one is still running.
- **Other processes.** Any process from the prefix would make a copy fail,
  kgd included. That is why `--ignore-running` is refused on Windows, and
  why the service is stopped before any file is copied.
- **The archive** is a `.zip`, unpacked by the restricted extractor (§4.2
  step 6).
- **Child processes.** The delegated installer is spawned with the console
  inherited (`platform.process.runInherit`), the same call as on POSIX.
- **`install.ps1`** gains `-ReleaseBase`. Update is the first
  published-release download path on Windows.

## 8. Failure and convergence

The installer writes in this order:

1. the record (new version);
2. the files, each atomically;
3. `manifest.json`;
4. the removal of dropped files;
5. the SDK;
6. the self check.

(`apps/cli/src/app/install.zig:164-218`.) A failure part-way leaves the record new and
the manifest old, or both new but with a file missing. The `intact`
measurement (§4.1 step 3) catches both states, so they are repaired instead
of reported as up to date.

Whichever executable is installed after such a failure carries `update`,
since both versions ship it. Running `metacodes update` again reinstalls the
target.

- **Ctrl+C during a download** removes the staging directory.
- **Ctrl+C during the install step** reaches the child through the
  terminal's process group, and the next run converges.
- **On Windows**, if the renamed executable could not be restored, the next
  run starts from it under its `.old` name. Update looks for the install
  beside the physical executable, so a `metacodes.exe.<pid>.old` in
  `<prefix>\bin` still finds its prefix.

Staging lives at `<prefix>/.update/run-<random>/` and is removed at
the end of each run; a crashed run's directory is removed by the next run
under the lock.

- **Why inside the prefix.** The staged `bin/metacodes` has to be executed.
  Linux hosts often mount `/tmp` `noexec`, and `install.sh`'s `mktemp` in
  `$TMPDIR` is exposed to that today. The prefix's owner can always write
  there.
- **Never mistaken for part of the install.** No manifest lists `.update/`,
  so the installer's `removeDropped` never touches it, and
  `install.sh --uninstall` removes it with the prefix.

## 9. Rollout

- The first release that ships `update` is the one after 0.7.0. Installs at
  0.7.0 or earlier reach it once through `install.sh`. That run also
  records the mirror they came from, and for `--dev` the checkout.
- A downgrade to a release without `update` warns that coming back needs
  `install.sh`.
- The first real update-to-update move is from that release to the next
  one, and it is checked by hand against GitHub when that release is
  published. A development install can be checked at once: update it, then
  rebuild it after a commit.

## 10. Change list

| File | Change |
|---|---|
| `apps/cli/src/app/update.zig` | options, `planRelease`, `planCheckout`, orchestration. The prefix is injected, so tests need no installed executable |
| `apps/cli/src/app/release_fetch.zig` | the curl invocations (latest tag, SHA256SUMS, archives) with their policy, the exit-code mapping, SHA256SUMS parsing and asset selection |
| `apps/cli/src/app/unit_archive.zig` | the restricted tar.gz and zip extractor |
| `src/platform/process_scan.zig` | the scan from §6.2 on macOS, Linux and Windows, and the stop from §6.2 |
| `apps/cli/src/app/install.zig` | `update_source` with `--release-base` and `--checkout`; make `isOlder`, the manifest readers and the `intact` measurement public |
| `apps/cli/src/main.zig` | the subcommand, its usage text and error hints, and the new install options |
| `scripts/install.sh`, `scripts/install.ps1` | pass `--release-base`, `--checkout` and `-ReleaseBase` to units that know them |
| `apps/cli/src/app/archive_fixture.zig` | test-only `.tar.gz` and `.zip` writers (and raw tar headers for hard links and devices) |
| `tests/_harness/update_unit_probe.zig`, `apps/cli/src/install_root.zig` | the fixture unit executable of §11 and the module root that gives it the installer |
| `tests/component/update_test.zig`, `tests/component/kgd_e2e_test.zig` | the L2 evidence of §11 |
| `doc/INSTALL_DESIGN.md`, `doc/API.md` (CLI surface), `doc/GETTING_STARTED.md`, `README.md`, `CHANGELOG.md` | document `update` and `update_source`; correct the §4 sentence (§6.1) |

## 11. Evidence

Declaration = wiring = L2 (AGENTS.md).

**L1:**

- the `planRelease` and `planCheckout` tables;
- the SHA256SUMS parser: malformed lines, duplicates, a missing asset, an
  ambiguous SDK;
- `Location` → tag;
- the https, loopback, user-info and downgrade-redirect policy;
- the extractor refusing symlinks, hard links, `..`, absolute paths, drive
  letters, duplicates and a second root, for tar and zip;
- `update_source` parsing and keeping;
- process classification over a synthetic process table.

**L2 (`tests/component/update_test.zig`):** a loopback HTTP server serves a
fixture release (`/latest` 302, SUMS, an archive built in the test). The
fixture unit's `bin/metacodes` is `zig-out/bin/update_unit_probe`, built on
every platform. Its `install` runs the real installer
(`apps/cli/src/app/install.zig`, without the doctor self check). Its `sleep` and
`kgd` modes stand in for a session and for the service with a `tinykgd`
child. Every invocation is recorded. The tests assert:

- the unit runs exactly `install --prefix <prefix> --upgrade --release-base
  <base>`, and the install it leaves is intact and records the mirror;
- a tampered archive and a mislabelled unit never run it and change nothing;
- a unit whose `install --help` predates `--release-base` is not given it;
- `up_to_date` and `newer_installed` download no archive (the server's
  request log shows this);
- a recorded mirror is used without `--release-base`;
- a missing file turns `up_to_date` into `repair`;
- a changed TinyKG digest runs `kg install`;
- `.update/` is empty afterwards;
- a failed installer is reported, leaves the executable in place (renamed
  back on Windows), and the next run repairs a half-written install;
- the checkout source runs a stub `scripts/install.sh` with exactly the §4.3
  arguments, and `up_to_date` runs nothing;
- a running session from the prefix refuses the update, `--ignore-running`
  goes ahead and names it (POSIX), and the service pair is stopped;
- `--check` names that session (text and `sessions[]`) and the service pid
  a real run then stops (`services[]`), changes nothing, and leaves
  `running_sessions` and `stopped_services` empty; with nothing running,
  all four arrays are empty;
- the real `install --help` names every flag of the contract, and the real
  `--help` names `update`.

Each wiring point was mutation-checked: dropping `--release-base`, skipping
the digest comparison, ignoring sessions or the service, skipping the repin,
or downloading for an up-to-date install each turns a named test red.

**L2, the §6.3 premise** (`tests/component/kgd_e2e_test.zig`): a real service
refuses a client holding a pin for other binaries, autostart would not start
one for that state, and `kg install` repins it with the key kept.

**Installer:** `install.zig` tests show that `--release-base` and
`--checkout` are recorded, kept and cleared as §3 says, and refused when
invalid. `scripts/tests/test_install_scripts.py` shows that `install.sh` and
`install.ps1` pass them only to units that know them.

**Real binary.** The PR pipeline builds pre-channel units
(`0.x.y-dev+<commit>`), and the release path refuses those by design: it
takes bare stable tags only. So CI cannot drive the real executable through
a release update. The probe above stands in for the unit, and the contract
test holds the real installer to the options update passes. The real path is
checked by hand against GitHub once two releases that ship `update` exist
(§9). A development install can be checked at once.

## 12. Decisions (2026-10-25)

1. **Running sessions:** the update is refused by default;
   `--ignore-running` overrides that on POSIX.
2. **Windows:** part of the first implementation.
3. **Mirror:** recorded in `install.json` at install time (`update_source`,
   §3), and used by later updates.
4. **Development installs:** rebuilt from the recorded checkout (§4.3);
   `--pull` is opt-in and fast-forward only.

## 13. The update notice (2026-11-21)

An interactive TUI start of a release install offers a newer release, the way
Codex does. Nothing else checks: `-p`, `-`, `serve`, `--web`, teammates and a
start whose stdin or stderr is not a terminal skip it, and so do a
development install (`update_source.kind = checkout`), an installed version
with a pre-release part, `METACODES_NO_PROBE` and `METACODES_NO_UPDATE_CHECK`.

- **The check runs in the background, once a day.** It asks the install's
  release base for `/latest` (§5, without curl's messages, which would draw
  over the TUI) and writes `<state root>/update-check.json`:
  `checked_at` (unix seconds), `base`, `latest` and `skipped`. A failed check
  keeps the last `latest` of the same base and waits a day too. Another base,
  or a clock that went back, checks at once.
- **The notice reads only that file**, so the session never waits on the
  network. A `latest` from the install's base that is newer than the installed
  version and is not `skipped` is offered before the TUI starts:

  ```text
  metacodes 0.14.0 is available (this install is 0.13.0).
    1. Update now
    2. Skip
    3. Skip until the next version
  Choice [2]:
  ```

  `1` runs `metacodes update` (§4.2) in this process, which is not yet a
  session, and exits after a successful update so the user starts the new
  version; a failed or refused update says why and the session starts. `3`
  records the version in `skipped`. Anything else skips it this time.

| File | Change |
|---|---|
| `apps/cli/src/app/update_notice.zig` | which installs are offered what, the cache file, the background check |
| `apps/cli/src/app/release_fetch.zig` | `Fetcher.echo_errors` |
| `apps/cli/src/main.zig` | the notice before an interactive session, and `metacodes update` from it |
