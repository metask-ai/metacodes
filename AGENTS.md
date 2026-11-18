# Contributor instructions

These rules apply to the entire repository.

## Engineering contract

- Use the Zig version declared by `build.zig.zon` and CI. Verify unfamiliar
  standard-library APIs against the installed toolchain instead of relying on
  memory from another Zig release.
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
- Preserve the kernel boundaries: plugins cannot replace the AgentLoop or bypass
  permission, sandbox, budget, formal verdicts, TinyKG admission, or artifact CAS.
- Provider-visible bytes are a cache contract. Runtime generation, plugin paths,
  journals, timestamps, and equivalent configuration churn must not enter prompts.
- TinyKG is a separately built external binary dependency. The repository owns one
  manually reviewed cross-platform binary bundle, selected by target and pinned
  by SHA-256. Never add TinyKG source vendoring, download-on-build, `PATH` search,
  sibling-checkout discovery, or stale build-output fallback.

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

- Work on a task branch in a dedicated worktree. When the change is ready,
  show the developer a summary of the diff and ask before shipping it. Only
  after an explicit yes, commit and run `python3 .github/pr-loop.py ship
  --title ... --body-file ...`: it pushes the branch with an ordinary push,
  opens the PR against **metask-ai/metacodes** (also when `origin` is a fork)
  and registers it. `submit` registers an already pushed branch and `bind` an
  existing PR. Follow the examples in
  [CONTRIBUTING](CONTRIBUTING.md#initial-development-setup).
- Register the invoking session explicitly. Codex sessions and Claude Code
  sessions are both supported (`--agent codex|claude`); run from inside the
  session, `ship` detects it from `CODEX_THREAD_ID` or `CLAUDE_CODE_SESSION_ID`.
  The checkout must be clean. Do not invent a session ID.
- The loop must stay visible to the developer. A PR shipped from a live
  session is attended: review feedback waits for that session instead of a
  background worker. Right after `ship`, watch
  `python3 .github/pr-loop.py inbox --pr N --follow`. When feedback arrives,
  show the developer `pr-loop.py feedback --pr N` in full, fix or rebut each
  finding in front of them, and answer with `pr-loop.py reply`; do not commit
  or push yourself. Reviews, replies and gate results are also mirrored to the
  PR conversation. Only when the session stays silent past its timeout does
  the watcher fork it into an unattended worker; `pr-loop.py attach --pr N`
  routes feedback back to the live session.
- Fix in the current session only what the PR introduced. A reviewer
  follow-up is a pre-existing defect outside this PR's scope: after the
  developer agrees, fix it in a new session and worktree and ship it as a
  separate PR. Never widen the current PR to absorb it.
- CI is repaired before review. Red required checks go back to the worker
  with the failed jobs' log excerpts; fix the root cause. Answer `rerun_ci`
  only with log evidence that the failure is unrelated to the change: it
  reruns once per head. The controller reviews each green head/base revision
  in a fresh, read-only, adversarial conversation, by default with the other agent than the worker
  (`--reviewer`). Blocking findings, failed CI and failed local validation go
  back to the saved repair worker. The worker may rebut a finding it believes
  is wrong instead of changing code; the next fresh review must rule on the
  rebuttal. A disagreement that survives two rebuttal rounds becomes a recorded
  decision. During repair, the worker edits; the controller
  owns checkpoint commits, `dx zig build gate:pr`, and ordinary pushes. Failed
  checkpoints stay local. A pushed revision receives a fresh review.
  Record review findings, repair summaries, validation, CI, pushes and merge
  outcomes in the PR timeline so they can be read without opening a worker.
- Review and repair are automatic work, not an additional `agent/review`
  commit-status gate. Unavailable tools and interrupted read-only reviews
  retry full review automatically. There is no fixed invocation or repair-round
  cap; keep both counters as durable audit evidence.
  Never substitute a limited review or manufacture approval after a timeout.
- Keep the PR branch current with main. The controller merges updated main,
  validates and pushes it, then requires fresh review and PR CI. Only the exact
  reviewed head with passing required checks and satisfied upstream reviews
  may be merged. Require strict up-to-date branch protection; no merge queue,
  deferred auto-merge or admin bypass. Preserve review-thread resolution and
  revision checks; a quiet reviewer is not an approval.
- High-risk heads wait for a human. A head needs an approval bound to its exact
  SHA when it touches a path in `.github/pr_loop/risk.py` (CODEOWNERS core
  directories, the permission, sandbox, formal and plugin boundaries,
  credentials, pinned binaries, build, release, CI, public API and agent
  policy) or when the reviewer classifies it as high risk. The watcher notifies
  the developer, comments on the PR once per head, and keeps repairing CI while
  it waits. Approve with a GitHub review on that commit, a maintainer comment
  `/approve <full sha>`, or `python3 .github/pr-loop.py approve --pr N --sha <sha>`.
  A later push requires a new approval. Never approve on the developer's behalf.
  Stale branches, merge conflicts and failed checks are not human work: the
  controller merges main and the worker resolves them.
- Ambiguous requirements, additional permissions, policy changes and interrupted
  writes require a recorded decision. Check with
  `python3 .github/pr-loop.py status`; the developer responds with
  `python3 .github/pr-loop.py answer --pr "$PR_NUMBER" --text "Your decision"`.
  Preserve progress and invocation/repair counters across restarts instead of
  resetting them or answering on the developer's behalf.

The [PR workflow guide](doc/PR_AGENT_LOOP.md) defines prerequisites, timeouts,
state storage and recovery. Keep these agent instructions and CONTRIBUTING
consistent with that guide when changing the workflow.

## Definition of done

Declaration = wiring = L2 evidence. A schema/config/API field is not implemented
until a component or integration test proves input X changes the real downstream
request, child process, durable state, or host-visible result Y. Silent no-ops are
not accepted.

Before submitting:

```sh
zig fmt --check build.zig src tests
zig build test:lib -Doptimize=ReleaseSafe
zig build test
scripts/test_coverage_audit.sh
python3 scripts/check_doc_links.py
python3 scripts/check_doc_facts.py
git diff --check
```

`zig build gate:pr` runs this list: the core suite always in ReleaseSafe, the
full suite at `-Doptimize` (Debug by default). CI runs the same commands (the
full suite in Debug, the core suite in ReleaseSafe;
`scripts/tests/test_gate_manifest.py` asserts every command above has a CI
step), so this block is the single source. CI runs the full suite as its
three parts, `zig build test:units`, `test:integration` and `test:product`, on
separate runners; `zig build test` is exactly those three, so a new check
goes into one of them, and a new CI step names its leg (`doc/CI_DESIGN.md`
§4, "Where a new check goes"). The one exception is a release or
reopen PR that adds only `scripts/release_cut.py`'s generated bump to a base
whose complete CI coverage passed: it takes the CI fast path
(`doc/RELEASE_AUTOMATION_DESIGN.md` §3). A change confined to documentation,
or to documentation and the evaluation harness, skips the CI suites it cannot
affect (`scripts/ci_scope.py`). CI runs once per PR revision on Linux x86_64,
macOS ARM64 and Windows x86_64; main pushes do not repeat it. Linux ARM64,
Intel macOS and Windows ARM64 cross-build checks run in the release workflow
(`doc/CI_DESIGN.md` §3); keep lightweight target-contract fixtures in PR CI.
Document deletions/moves use link and protocol-reference checks;
release-document changes use `release:docs:check`, which shares the release
copy steps without compiling the product.
The local `gate:pr` checklist above remains unchanged. Run the full suite with
`-Doptimize=ReleaseSafe` as well when a change touches unsafe code or an ABI.

The Python steps need Python >= 3.9 and PyYAML (`requirements-dev.txt`).

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
