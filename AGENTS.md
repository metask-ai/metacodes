# Contributor instructions

These rules apply to the entire repository.

## Engineering contract

- Use the Zig version declared by `build.zig.zon` and CI. Verify unfamiliar
  standard-library APIs against the installed toolchain instead of relying on
  memory from another Zig release.
- Toolchain compatibility and Zig API compatibility are separate contracts. The
  Zig API snapshot records the Zig version it was generated with, and
  `test:contract` fails when the toolchain differs from it or from
  `build.zig.zon`. Upgrade the toolchain in its own PR and regenerate the
  snapshot there with `-Dupdate-contract`; never combine it with a package
  split or with removing or renaming public exports (`tests/README.md`).
- Develop type first: define the state model and signatures, then let the compiler
  drive the implementation.
- Make illegal states unrepresentable. Prefer tagged unions, distinct ID types,
  explicit error sets, and compile-time validation over optional-field protocols.
- Every allocation has an owner. Name allocators by lifetime (`gpa`, `arena`,
  `scratch`) and place `defer` immediately after successful resource acquisition.
- Path-taking file operations go through `src/platform/fs.zig` (`open`,
  `openZ`, `mkdir`, `rmdir`, `chdir`, `chmod`, `fopen`, `unlinkPath`,
  `renameReplace`, `exists`, `realpath`, `finalPath`, `getCwd`) and the
  environment/cwd through `platform.paths`/`util.fs`, never through the
  `std.c.*` spellings: on Windows those are the narrow CRT entry points, which
  decode UTF-8 paths with the ANSI code page and reach a different file than
  the wide-character checks do (POSIX-only code and fixed ASCII device paths
  such as `/dev/null` are the only exceptions). `realpath` is lexical on
  Windows; use `finalPath` when you need the physical path. Read errno through
  `pfs.lastErrnoIs`/`pfs.errnoTag`, not a bare `@enumFromInt` or
  `std.posix.errno`.
- Create every `std.Io.Threaded` through `platform.signal.threadedIo`, never
  `std.Io.Threaded.init`: std's init replaces the ignored SIGPIPE with a
  handler, and a delivered SIGPIPE turns any thread's blocked syscall into
  EINTR (`zig build test:io-threaded` enforces it).
- Spawn production threads through `platform.thread.spawn(stack, ...)`, never
  `std.Thread.spawn`: std's 16 MiB default stack is a 16 MiB commit per thread
  on Windows. Pick the `Stack` class by what the thread runs; outside test
  blocks `zig build test:thread-stack` enforces it.
- The REPL's SIGWINCH handler has no SA_RESTART either. In `src/repl/`, read
  keys through `input.readKey` or check `input.retryInterruptedRead` right
  after a raw read, and write to the terminal through `pfs.writeAll`; a call
  that cannot see EINTR says `// no EINTR: <reason>` on its line
  (`zig build test:terminal-io` enforces it).
- The TUI's scrollback has no undo: in `src/repl/`, only the Renderer
  (`RenderRegion`) erases the screen or writes past the inline region. Erase
  with ED 0, reset the screen only through `RenderRegion.resetScreen`, climb
  with relative moves instead of saving the cursor, and send scrollback text
  through the Renderer; any other direct terminal write is listed with its
  reason ([doc/TUI_VIEWPORT_OWNERSHIP.md](doc/TUI_VIEWPORT_OWNERSHIP.md);
  `zig build test:scrollback` enforces it).
- Session state leaves the machine for a service only where the user named it.
  No built-in destination that is on by default is a non-loopback `http://`
  URL, and the CLI takes no built-in System-One advisor (`jev.BUILTIN_DEFAULT`
  is for a host that sets `Config.jev_builtin_default`, none here): name a
  service in `config.json` or the environment, or use https
  (`zig build test:builtin-egress` enforces it, #474).
- Receive an HTTP response in `src/` with `http_connection.receiveHead` and
  read its body with `http_connection.bodyReader`
  (`src/api/http_connection.zig`), never with std's `Request.receiveHead`,
  `Response.reader` or `Reader.bodyReader`: Zig 0.16 reads the body of a
  1xx, 204 or 304 answer, and `Request.deinit` drains it, until the server
  closes the connection (`zig build test:http-answer` enforces it, #579).
- A request in `src/` that sets `keep_alive = false` calls
  `http_connection.keepServerOpen` before it is sent. Otherwise std writes
  `connection: close` for it, the server closes right after its last byte,
  and behind a transparent proxy that close can overtake the end of the
  answer (`zig build test:keep-server-open` enforces it, #573, #661).
- Agents do not write comments, doc comments or docstrings. Let names, types
  and structure carry the meaning, and put the reasoning behind a change in
  its commit message or PR description. The exceptions are what this file or
  a check requires (`// no EINTR: <reason>`, the stated reason for a listed
  terminal write), tool directives (`# shellcheck disable=...`, `# noqa`,
  `# type: ignore`) and shebangs. Leave existing comments alone unless the
  code they describe changes; then correct or delete them.
- Preserve the kernel boundaries: plugins cannot replace the AgentLoop or bypass
  permission, sandbox, budget, formal verdicts, TinyKG admission, or artifact CAS.
- Packages depend downward only. `layers.zon` declares the packages from the
  lowest (`base`) to the highest (`cli`, then `testing` and `tests`) and
  assigns every `.zig` file under `src/` and `tests/` to one of them by path.
  A package's `allowed_dependencies` lists the packages it may import, never
  the ones that import it, and names only packages declared before it. A new
  file belongs to a package before it lands. `zig build layer:check` holds
  every `@import` to those lists from the file that writes it, test blocks
  and named modules included, and every `build.zig` module import too, and
  finds package cycles, deep imports into another package's files and module
  roots wide enough to reach packages they may not depend on.
  `layer_baseline.zon` records today's violations file edge by file edge and
  only shrinks: a new violation fails, and so does an entry whose violation
  is gone, so delete it in the change that removes it (`zig build
  layer:baseline` prints the baseline that matches the tree). The kernel's
  `kernel_budget` (lines and the packages it reaches) only goes down. CI
  checks the PR against its base (`zig build layer:check -Dlayer-base=<ref>`)
  and fails when the baseline or the budget grows or `allowed_dependencies`
  widen. A change to the layering itself goes in its own PR. The base
  comparison accepts an entry a package split exposes only when the base
  tree already had that import between two files of one package; an upward
  entry must already be upward in the base, while a deep one may come from
  either list. A package may start depending on a package the base lacks
  only when that package's dependencies and its files, each at a path the
  base already assigned, were already within the dependent's reach. `src/lib.zig`, the
  `metacodes-core` facade that re-exports the lower packages, is its own
  `facade` package between `teamwork` and `agentcore`.
- Provider-visible bytes are a cache contract. Runtime generation, plugin paths,
  journals, timestamps, and equivalent configuration churn must not enter prompts.
- TinyKG is a separately built external binary dependency. The repository owns one
  manually reviewed cross-platform binary bundle, selected by target and pinned
  by SHA-256. Never add TinyKG source vendoring, download-on-build, `PATH` search,
  sibling-checkout discovery, or stale build-output fallback.

## Preview features

Every preview feature has its own switch; there is no umbrella flag to hide a
new feature behind. Users pick features one by one with
`--preview=<list>` / `--no-preview=<list>` or a root `"preview"` object in
`config.json`, and `--preview` / `--no-preview` / `"preview": true` switch them
all ([doc/API.md](doc/API.md#preview-features)). When you add a preview feature:

- Add its name to `PreviewFeature` and a field of the same name to
  `PreviewFeatures` in `src/types.zig`, shrinking `_unused` by one bit; `all`,
  `has`, `with` and `max_arg_len` derive from the enum, and a field without a
  matching name fails to compile. The name is what users type, so use
  `snake_case`.
- Gate the feature on its own field and nothing else: `opts.preview.<name>`,
  `ctx.preview.<name>`, or `.preview_feature = .<name>` on a tool's registry
  entry. Never gate on another feature's field, on "any feature enabled", or on
  a new `bool`; never require `--preview` in addition to a flag of its own.
  A feature that already has a dedicated selection flag (HarnessMM's
  `--harnessmm`, RSI's `--rsi`) is selected by that flag alone.
- Pass the existing `preview.Features` value through; do not add a parallel
  field. Child agents, Teamwork seats and teammate processes already inherit
  the resolved set.
- Prove independence with an L2 test: `--preview=<name>` enables it,
  `--preview=<another feature>` and `--no-preview=<name>` leave it off, and a
  saved `{"preview": {"<name>": true}}` enables it
  (`tests/component/state_env_test.zig` shows the pattern for the CLI).
- Document it in the same change: the feature table in
  [doc/API.md](doc/API.md#preview-features), the feature list in
  [doc/LOCAL_CONFIG.md](doc/LOCAL_CONFIG.md#preview-features), the `--preview`
  help text in `src/main.zig`, and `CHANGELOG.md`.
- The AgentCore ABI has no per-feature selection: `RuntimeConfigV1.preview = 1`
  enables every feature. Adding one there is an ABI revision.

## PR review and repair workflow

The developer starts one local watcher during initial development setup,
from a checkout containing the tooling, and keeps it running while PRs are
being delivered:

```sh
python3 .github/pr-loop.py run
```

The watcher runs on the developer's Mac; local builds and validation run on
devbox through `dx`. Closing its terminal or taking the Mac offline pauses
local review and repair. Registration alone does not start the watcher.
Before handing a PR over, confirm that the developer has the watcher running.

- Submit PRs to **metask-ai/metacodes**, including when `origin` is a fork.
  Use `python3 .github/pr-loop.py submit` to create and register a PR, or
  `python3 .github/pr-loop.py bind` for an existing PR. Follow the command
  examples in [CONTRIBUTING](CONTRIBUTING.md#initial-development-setup).
- Register the original Codex thread ID and its dedicated worktree explicitly.
  The branch must already be pushed, the checkout must be clean, and the
  thread must be accessible to the local App Server. Hand the thread over
  idle and avoid concurrent edits by another host. Do not invent a thread ID
  or claim automatic delivery when these prerequisites are missing.
- The controller reviews each head/base revision in an independent read-only
  conversation. Blocking findings, failed CI and failed local validation go
  back to the original worker. During repair, the worker edits; the controller
  owns checkpoint commits, `dx zig build gate:pr`, and ordinary pushes. Failed
  checkpoints stay local. A pushed revision receives a fresh review.
- Keep the PR branch current with main. The controller merges updated main,
  validates and pushes it, then requires fresh review and PR CI. Only the exact
  reviewed head with passing required checks and satisfied upstream reviews
  may be merged. Require strict up-to-date branch protection; no merge queue,
  deferred auto-merge or admin bypass. Preserve review-thread resolution and
  revision checks; a quiet reviewer is not an approval.
- Ambiguous requirements, additional permissions, policy changes, interrupted
  writes and exhausted limits require a recorded decision. Check with
  `python3 .github/pr-loop.py status`; the developer responds with
  `python3 .github/pr-loop.py answer --pr "$PR_NUMBER" --text "Your decision"`.
  Preserve progress and invocation limits instead of restarting an unlimited
  repair loop or answering on the developer's behalf.

The [PR workflow guide](doc/PR_AGENT_LOOP.md) defines prerequisites, limits,
state storage and recovery. Keep these agent instructions and CONTRIBUTING
consistent with that guide when changing the workflow.

## Definition of done

Declaration = wiring = L2 evidence. A schema/config/API field is not implemented
until a component or integration test proves input X changes the real downstream
request, child process, durable state, or host-visible result Y. Silent no-ops are
not accepted.

Before submitting:

```sh
zig build gate:static
python3 scripts/lint.py
zig build test:lib -Doptimize=ReleaseSafe
zig build test:affected
scripts/test_coverage_audit.sh
python3 scripts/check_doc_links.py
python3 scripts/check_doc_facts.py
git diff --check
```

`zig build gate:static` runs only the guards that read the source:
`zig fmt --check build.zig src tests`, the scans of `http-status:gate`,
`subsystem:boundary` and `layer:check` (their self-tests run in `test:units`), the
`scripts/tests/test_*_discipline.py` scans and `git diff --check`. It takes seconds, and it comes first because the build
runner has no fail-fast: inside the full gate a failed guard is reported
only when everything else has finished (#587). Every CI gate leg runs it
first too.

`zig build test:affected` runs the part of `zig build test` that CI selects
for the change against `origin/main`, working tree included
(`scripts/ci_scope.py`, `doc/CI_DESIGN.md` §2): all of it for most changes,
less when only tests or packages `layers.zon` trusts changed. The full suite
is left to CI's full runs and main's nightly run. `zig build gate:pr` runs
this list with the full suite in place of `test:affected`: the core suite
always in ReleaseSafe, the full suite at `-Doptimize` (Debug by default). CI
runs the same commands (the full suite in Debug, the core suite in ReleaseSafe;
`scripts/tests/test_gate_manifest.py` asserts every command above has a CI
step), so this block is the single source. CI runs the full suite as its
three parts, `zig build test:units`, `test:integration` and `test:product`, on
separate runners; `zig build test` is exactly those three, so a new check
goes into one of them, and a new CI step names its leg (`doc/CI_DESIGN.md`
§4, "Where a new check goes"). The one exception is a release or
reopen PR that adds only `scripts/release_cut.py`'s generated bump to a base
whose complete CI coverage passed: it takes the CI fast path
(`doc/RELEASE_AUTOMATION_DESIGN.md` §3). A change confined to documentation,
to documentation and the evaluation harness, to tests, or to packages whose
`layer_baseline.zon` entries are gone, skips the CI suites it cannot affect
(`scripts/ci_scope.py`). CI runs once per PR revision, and again when its labels change, on Linux x86_64,
macOS ARM64 and Windows x86_64; main pushes do not repeat it. Linux ARM64,
Intel macOS and Windows ARM64 cross-build checks run in the release workflow
(`doc/CI_DESIGN.md` §3); keep lightweight target-contract fixtures in PR CI.
Document deletions/moves use link and protocol-reference checks;
release-document changes use `release:docs:check`, which shares the release
copy steps without compiling the product.
The local `gate:pr` checklist above remains unchanged. Run the full suite with
`-Doptimize=ReleaseSafe` as well when a change touches unsafe code or an ABI.

The Python steps need Python >= 3.9 and PyYAML (`requirements-dev.txt`);
`scripts/lint.py` needs the linters at the versions `requirements-lint.txt`
pins (ruff for Python, shellcheck for shell scripts, actionlint for
workflows) and fails when one is missing.

The native bundled TinyKG is wired into tests by default. Supply
`-Dtinykg-bin` and `-Dtinykg-sha256` together only to audit an explicit override.
Do not run paid or provider-backed benchmarks without explicit user authorization.

Judge a build by its exit code and `Build Summary`, never by the presence of
`failed command:`. The Zig 0.16 build runner routes every step that wrote to
stderr through the failure printer, so a passing step is tagged ` w` and
followed by `failed command: <cmd> --listen=-` while the build still exits 0
(`master` renames that tag to ` stderr` but keeps the wording). Suites whose
subject logs diagnostics on expected error paths trip this on every run;
`agentcore-abi-contract` does so through its HTTP 529 and connection-drop tests.

## Repository hygiene

- Keep secrets, personal paths, generated evaluation runs, binaries, and local
  TinyKG stores out of Git. The manifest-pinned release assets under
  `vendor/tinykg/bin/` and `vendor/ripgrep/bin/` are the only binary
  exceptions; both are manually reviewed upstream artifacts pinned by SHA-256
  and inventoried by their verify scripts.
- Use `rg`/`rg --files` for discovery and `apply_patch` for source edits.
- Do not overwrite unrelated worktree changes. Destructive Git commands require
  explicit authorization.
- Public API changes must update `doc/API.md`, the normative protocol document,
  SDK fixtures, and an end-to-end consumer test in the same change.
