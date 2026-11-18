# PR review and repair loop

`python3 .github/pr-loop.py` is an opt-in delivery controller for PRs submitted
to **metask-ai/metacodes**. It registers a PR with the Codex or Claude Code
session that wrote it and its worktree, reviews each revision adversarially,
returns actionable feedback to a fork of that session, validates and pushes
repairs, holds high-risk revisions for a human, and requests an exact-head
upstream merge after validation against current main. Decisions and interrupted writes stop in a durable
`needs_decision` state. Ordinary review findings, failing CI and failed local
validation return to the worker automatically, with no fixed call or repair-round cap.
Tool availability failures and interrupted read-only reviews also retry
automatically. Review is part of the repair loop, not an extra GitHub status gate.
Transient GitHub read failures retry on later polls without spending an agent
invocation. Failed remote mutations still require reconciliation.

This is contributor tooling, not a metacodes runtime API. It runs on the
contributor's Mac; local builds, tests and gates run on devbox through `dx`.
The existing GitHub-hosted CI and `Protect main` rules remain the final merge
authority. See [CI design](CI_DESIGN.md) for the four required result checks
and the existing `merge_group` wiring.

The launcher and controller package live in [`.github/`](../.github/pr-loop.py).
Start the watcher as part of the contributor's initial development setup;
[CONTRIBUTING](../CONTRIBUTING.md#initial-development-setup) includes the setup
and per-PR registration checklist. Run it on your computer throughout the PR
lifecycle and restart it after closing its terminal or restarting the computer.
Placing the script in `.github/` does not make it a hosted Actions workflow.

## Delivery flow

1. The developer states a requirement in a local Codex or Claude Code session.
2. That session makes the change on a task branch in a dedicated worktree.
3. It shows the developer the change and asks. After an explicit yes it
   commits and runs `ship`, which pushes the branch, opens the PR and
   registers the session, the worktree and both agents.
4. CI comes first. The watcher waits for the four required checks on the
   head. A failure goes to the worker with the failed jobs' error lines and
   log tails, which the controller downloads because the worker has no
   network. The worker fixes the root cause, and the controller validates and
   pushes, until CI is green. A failure the logs show to be unrelated (runner
   outage, network flake) can be answered with `rerun_ci`: the failed jobs
   rerun once per head, and a second failure goes to the developer.
   Only a green head gets a fresh, read-only, adversarial review of the exact
   head/base revision, by default with the agent that did not write the code.
5. Findings go back to the developer's own live session (attended; see
   [Visible review conversation](#visible-review-conversation)), or to a
   dedicated fork of it when unattended. The worker repairs each finding or
   rebuts it with an argument; the next fresh review rules on each rebuttal.
   Pre-existing defects come back as non-blocking follow-ups for a separate
   session and PR. The controller validates, commits and pushes repairs, merges a
   moved main itself, and returns conflicts and CI failures to the worker.
6. Every pushed repair repeats CI first, then review, until one head is green
   and passes review.
7. A normal-risk head is merged. A high-risk head, or a disagreement that
   survives two rebuttal rounds, waits for a human (see
   [Human approval](#human-approval)).

## Prerequisites

- Python 3.9+, Git, authenticated GitHub CLI (`gh`), Codex CLI with the
  stdio App Server protocol, and Claude Code CLI (`claude`) with print mode
  and structured output. Only the agents a binding names are invoked.
  No additional Python packages are required.
- An already pushed PR branch in a clean, dedicated worktree. Its configured
  push remote must point to the PR's head repository. The target is upstream
  `metask-ai/metacodes`, even when that remote is a contributor's fork.
- A persisted source session. For Codex, a chat accessible to the local App
  Server whose `cwd` is that worktree; a desktop or remote chat is usable only
  if that host exposes its history to this App Server. For Claude Code, a
  session ID `claude --resume` can open. The watcher derives a separate repair
  worker from that session. Continue discussion in the source chat and keep edits
  in the bound worktree exclusive to the active worker.
- `dx` configured for the worker checkout. The controller always executes
  `dx zig build gate:pr` before pushing an automatic repair. It saves local
  checkpoint commits first: some evaluation tests materialize committed HEAD
  and intentionally refuse dirty pinned inputs. A failed checkpoint is never
  pushed. Its validation output goes back to the repair worker.
- GitHub permission to push the head branch and merge the PR upstream.
  No admin bypass is used or requested.

Codex and Claude Code use their existing local authentication. The controller does not copy
credentials to GitHub Actions, read auth tokens or write secrets to PR bodies.
Agent calls incur the signed-in account's normal usage. The watcher has no fixed
cap on agent calls or repair rounds. It retains both counters for audit and keeps
working through review findings and validation failures. Each agent or gate
invocation still has a configurable timeout, thirty minutes by default.

## New PR entry point

After the developer confirms the change, the session that wrote it commits
and ships it from its worktree. `ship` pushes the current branch to `--remote`
(default `origin`) with an ordinary push, creates the PR **in the mother
repository** and binds it:

```sh
python3 .github/pr-loop.py ship \
  --title "fix: describe the change" \
  --body-file "$PR_BODY_FILE"
```

Run inside Claude Code, `ship` binds `CLAUDE_CODE_SESSION_ID` as a `claude`
worker; inside Codex, `CODEX_THREAD_ID` as a `codex` worker. Pass `--agent`
and `--thread` to register another session. `--reviewer` defaults to the
other agent. `ship` refuses `main`.

For a branch that is already pushed, `submit` creates and binds the PR.
Supply your own branch and thread ID:

```sh
python3 .github/pr-loop.py submit \
  --repo metask-ai/metacodes \
  --worktree "$TASK_WORKTREE" \
  --thread "$TASK_THREAD_ID" \
  --head "$GITHUB_OWNER:$TASK_BRANCH" \
  --title "fix: describe the change" \
  --body-file "$PR_BODY_FILE"
```

The branch must already be pushed. `--repo` defaults to
`metask-ai/metacodes`; the command never infers the target from `origin`.
`--thread` can be omitted when the invoking agent supplies its session ID.
Thread IDs and local paths are stored locally, not in the public PR.

For a PR created with another tool, register it explicitly:

```sh
python3 .github/pr-loop.py bind \
  --repo metask-ai/metacodes --pr "$PR_NUMBER" \
  --worktree "$TASK_WORKTREE" --thread "$TASK_THREAD_ID"
```

Registration is idempotent for an identical binding. An active worktree or
thread cannot own two PRs. The controller processes only registered PRs; it
does not adopt unrelated open PRs or grant public PR authors execution access
to the local host.

Start the watcher on the Mac, from the tooling checkout:

```sh
python3 .github/pr-loop.py run
```

Keep it in a persistent terminal or your service supervisor. The watcher polls
registered PRs every sixty seconds, so PR creation and subsequent pushes
trigger work without a public webhook receiver or provider secrets in CI.
Use `run --once` for one reconciliation pass, or `run --interval 30` to change
the polling period. Keep one watcher per state database; overlapping
reconciliation passes are refused by its process lock.
New PR registration remains available while another PR is being processed.
Answer commands should be run between reconciliation passes.

## PR timeline

```sh
python3 .github/pr-loop.py timeline --pr "$PR_NUMBER" --follow
python3 .github/pr-loop.py timeline --pr "$PR_NUMBER" --format html
```

The timeline stores the review report and reviewer ID, repair summary and
worker ID, local validation result and log path, CI result, published
revision, and merge outcome. Its JSON output includes a cursor for fetching
only subsequent events with `--after`. Render a snapshot in the source chat
where its refresh button can request a new snapshot in that same conversation.
The watcher records events locally. Automatically posting each event into a
desktop chat requires a chat-side consumer. The timeline commands read state
without starting or resuming an App Server conversation.

Existing PR registrations acquire their dedicated worker on the next allowed
repair. The upgrade preserves review history, checkpoints, decisions, and
counters. Older records contain only the events the previous watcher saved.
Validation logs live in the private directory alongside the SQLite database.

## Visible review conversation

A PR shipped from a live session is **attended** (`--attended`, the default
when `ship` detects the session; `--no-attended` otherwise). Review feedback
is not sent to a background worker. The watcher stores it, enters
`awaiting_session`, notifies the developer and waits for that session:

```sh
python3 .github/pr-loop.py inbox --pr "$PR_NUMBER" --follow   # one line per loop event
python3 .github/pr-loop.py feedback --pr "$PR_NUMBER"         # the waiting findings, in full
python3 .github/pr-loop.py reply --pr "$PR_NUMBER" --result updated \
  --summary "What changed" [--rebuttal "INDEX:argument"]
```

The session edits the bound worktree in front of the developer and replies. It
does not commit or push. The watcher admits the reply exactly like a worker
turn: checkpoint, `gate:pr`, push and fresh review. A failed gate returns to
the same session. While the session edits, a moved main does not interrupt
it; the next pass merges main. With no reply after `attended_timeout` (one
hour), the watcher records `attended_timeout` and forks an unattended worker
from the session. `attach --pr N` re-attaches the source session, and
`attach --pr N --off` detaches it.

With `--mirror` (the default for `ship` and `submit`) every adversarial review
(findings, follow-ups, risk), every repair reply (summary, rebuttals, pushed
SHA), gate failures and approvals are posted on the PR conversation. Before
anything is posted, the developer's `answer` texts are kept local and
redacted from it. The human-approval notice is built only from controller
text: path rules and a count of the reviewer's concerns.

## Adversarial review and rebuttals

The reviewer is told to find reasons the PR must not merge: error and cleanup
paths, allocation ownership, concurrency, platform differences, the provider
cache contract, kernel boundaries and tests that declare without proving.
It reports only blocking defects the PR introduces, each with a failure
scenario and an acceptance condition, and it classifies the revision's risk.
A real defect that already exists on the base and that the PR neither causes
nor touches is a `followup`: it does not block the merge, it is recorded and
mirrored, and the session fixes it in a new session and a separate PR. The
reviewer reads a controller-written `pr.diff` next to the snapshot.

A worker that believes a finding is wrong returns a rebuttal naming the
finding's index and arguing from the code. `disputed` means it changed
nothing: the same revision goes to a fresh reviewer with the rebuttals and is
neither validated nor pushed. `updated` may carry rebuttals for the findings it
left alone. A passing review clears the dispute. A third rebuttal round on one
PR becomes a `needs_decision` for the developer.

## Human approval

A revision needs a human approval bound to its exact head SHA when either:

- a changed path is a script that a workflow on the trusted base runs
  directly (for example `scripts/ci_scope.py`), or matches a rule in
  [`.github/pr_loop/risk.py`](../.github/pr_loop/risk.py): the CODEOWNERS core
  directories, the permission, sandbox, formal and plugin boundaries,
  credentials and authentication, pinned binaries, the build graph and
  toolchain pins, release and CI scripts, the public API contract, `.github/`
  and `AGENTS.md`; or
- the adversarial reviewer sets `risk.level` to `high`, for example for data
  deletion or migration, authentication, release or branch policy, a public API
  or wire-format break, or a change too broad to verify.

The rules run from the watcher's checkout, never from the candidate, so a PR
cannot weaken its own gate. As soon as the review passes, the watcher records
the request, notifies the developer and comments on the PR, once per head. With
`run --human-reviewer LOGIN` it also requests that reviewer. CI repairs
continue meanwhile. After review and checks pass, the PR stays in
`needs_human` until one of these names the current head:

- an `APPROVED` GitHub review on that commit by a collaborator with write,
  maintain or admin access (GitHub does not let authors approve their own PR);
- a PR comment `/approve <sha>` with the full 40-digit SHA by a maintainer or
  admin, so that an abbreviation can never match a later commit;
- `python3 .github/pr-loop.py approve --pr "$PR_NUMBER" --sha "$HEAD_SHA"`.

Any push changes the head and needs a new approval. Stale branches, conflicts
and failing checks never wait for a human; they go to the worker.

## Decisions and recovery

```sh
python3 .github/pr-loop.py status
python3 .github/pr-loop.py answer --pr "$PR_NUMBER" \
  --text "Keep compatibility with the existing response; add an optional field."
```

Only entering `needs_decision` emits a notification (stderr and a local macOS
notification). Repeated polling stays quiet. The reason is durable even if
desktop notifications are unavailable. A response becomes context for the
next review or worker turn. Partially edited files are preserved for that
continuation. No automatic reset, force push or deletion of worker changes is
performed.

Invocation and repair-round counts persist across commits and restarts, without
stopping work at a fixed number. Legacy registrations' `max_agent_runs` and
`max_rounds` fields are ignored. A PR already paused by the old count cap can
resume through `answer` with the developer's recorded decision; its review,
checkpoint and counters are preserved. Count-extension flags are no longer used.

The default SQLite database is
`~/.local/state/metacodes/pr-loop.sqlite3`. Use the global `--state PATH`
option before the subcommand to select another database. Keep it outside the
repository: it contains local paths, thread IDs, review evidence and decisions.
Its event log records state transitions. A crash during review, repair,
validation, push, base update or merge preserves progress on restart. An
interrupted read-only review retries automatically; interrupted writes are
escalated instead of replaying an operation with an uncertain outcome.
Inspect the worktree and PR before
answering; an answer does not automatically reconcile a divergent checkout.

## Admission contract

1. A review is a fresh, persisted, read-only Codex or Claude Code conversation in a detached snapshot.
   Persisting the reviewer retains its identity and audit history; it never
   reuses the original worker's context.
   It returns schema-validated `pass`, `fix_required`, `retry` or `needs_decision`,
   and a `risk` level with a reason for each high-risk concern. Reports stored
   before risk classification are discarded and reviewed again.
   A passing report cannot contain unresolved findings or a question.
   A tool or repository-access failure returns `retry` with no findings or
   decision question. The next poll starts a complete review of the current
   revision. Transport failures and read-only timeouts use the same path;
   spent invocations remain counted. No review from excerpts is substituted.
2. Reports are bound to both head and base SHA. A changed revision invalidates
   them; the controller rechecks the revision after review, repair and local
   validation, and immediately before merging.
3. The first repair forks the persisted source chat and saves the new worker ID
   before any edit turn. Later repairs resume that worker by ID. The source chat
   stays available for discussion. The worker edits the bound checkout and must
   have exclusive access for edits. The controller owns validation, commit, ordinary push
   and exact-head merging. Policy, workflow and controller edits require
   a decision. The worker's network is disabled; the controller executes the
   devbox gate and returns failures as feedback. Writable tool access is
   limited by Codex's workspace sandbox. Claude Code gets no Bash or other
   code-running tool (reviewer: Read/Glob/Grep; worker: plus Edit/Write,
   confined to the checkout by `acceptEdits`), user settings only, no MCP
   servers and `--permission-prompts none`. A Claude fork's ID is reserved
   before launch, and a fork that never launched is created on the next
   repair. Approval and user-input requests are escalated or denied rather
   than fabricated.
4. The four existing gate result checks must report **success** for the current
   PR head before it is reviewed and again when it merges, from the GitHub Actions app (PR workflows execute the test merge,
   but their check runs are attached to the head SHA). Missing, pending,
   skipped, neutral and untrusted-source results never satisfy this test.
   GitHub additionally enforces current approvals and review-thread resolution.
5. A stale branch receives an ordinary merge commit from current main, local
   validation and a push, followed by fresh review and PR CI. Conflicts go to
   the worker. The merge API receives the exact reviewed head SHA. Effective
   branch rules must require all four checks from GitHub Actions and an
   up-to-date branch, with no merge queue. GitHub must confirm the merge;
   no deferred auto-merge request or admin bypass is used.
6. A high-risk revision merges only with a human approval of its exact head
   (see [Human approval](#human-approval)).

The controller stores its review evidence and progress locally. It does not
publish an `agent/review` commit status or add a required review check to the
repository. Findings drive automatic repairs; transient read-only failures
drive automatic retries. Existing GitHub CI, upstream reviews, thread
resolution and exact-head merge requirements still apply. Legacy commit
statuses already published on older heads are historical records; retiring
one does not mean a code review passed.

## Verification

```sh
dx zig build test:pr-loop
```

This suite also runs in `test:units` on every PR. It uses real temporary Git
repositories and pushes to a local bare repository, a fake stdio Codex process,
and recorded GitHub API requests. It proves review → dedicated-worker repair →
validation → push → fresh review → exact-head merge → observed merge, without
provider calls. It also exercises stale review rejection, CI failures, busy
workers, decision recovery, the replayable timeline, durable counters, legacy
registrations, policy edits and interrupted
operations. It also proves unavailable tools → full review retry → repair →
validation → fresh review → merge without publishing a review status gate;
a Claude Code worker forked once and then resumed, reviewed by Codex, and
recovery from a fork that never launched; a read-only Claude Code reviewer;
rebuttal → fresh review → merge, the dispute limit, and an answered deadlock
reaching a fresh reviewer; core paths, workflow entry points and reviewer
risk → one notice → exact-head local, review or full-SHA comment approval →
merge; attended feedback → session reply → gate → push → merge, including a
gate failure, a moved main and the silent-session fallback; the mirrored PR
conversation with private decisions redacted; a missing reviewer executable
retrying; bounded process-tree cleanup; and `ship` validating the head
repository before it pushes, opens and binds.
No live PR is opened or merged by the tests.

Protocol references: [Codex App Server](https://learn.chatgpt.com/docs/app-server),
[GitHub protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).
