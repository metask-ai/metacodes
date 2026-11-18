# PR review and repair loop

`python3 .github/pr-loop.py` is an opt-in delivery controller for PRs submitted
to **metask-ai/metacodes**. It registers a PR with its original Codex thread
and worktree, independently reviews each revision, returns actionable feedback
to that thread, validates and pushes repairs, and requests an exact-head
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

## Prerequisites

- Python 3.9+, Git, authenticated GitHub CLI (`gh`) and Codex CLI with the
  stdio App Server protocol. No additional Python packages are required.
- An already pushed PR branch in a clean, dedicated worktree. Its configured
  push remote must point to the PR's head repository. The target is upstream
  `metask-ai/metacodes`, even when that remote is a contributor's fork.
- A persisted source chat accessible to the local App Server, whose `cwd`
  is that worktree. The watcher derives a separate repair worker from that chat.
  A desktop or remote chat is usable only if that host exposes its history
  to this App Server. Continue discussion in the source chat and keep edits
  in the bound worktree exclusive to the active worker.
- `dx` configured for the worker checkout. The controller always executes
  `dx zig build gate:pr` before pushing an automatic repair. It saves local
  checkpoint commits first: some evaluation tests materialize committed HEAD
  and intentionally refuse dirty pinned inputs. A failed checkpoint is never
  pushed. Its validation output goes back to the repair worker.
- GitHub permission to push the head branch and merge the PR upstream.
  No admin bypass is used or requested.

Codex uses its existing local authentication. The controller does not copy
credentials to GitHub Actions, read auth tokens or write secrets to PR bodies.
Agent calls incur the signed-in account's normal usage. The watcher has no fixed
cap on agent calls or repair rounds. It retains both counters for audit and keeps
working through review findings and validation failures. Each agent or gate
invocation still has a configurable timeout, thirty minutes by default.

## New PR entry point

From the checkout containing this tooling, create a PR **in the mother
repository** and bind it in one command. Supply your own branch and thread ID:

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
`--thread` can be omitted when the invoking agent supplies `CODEX_THREAD_ID`.
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
only subsequent events with `--after`. Read it while the watcher is working and
render a snapshot in the source chat when a contributor asks for progress.
The watcher records events locally. Updating the contents of a desktop chat
automatically requires a chat-side consumer. The timeline commands do not
start or resume an App Server conversation.

Existing PR registrations acquire their dedicated worker on the next allowed
repair. The upgrade preserves review history, checkpoints, decisions, and
counters. Older records contain only the events the previous watcher saved.
Validation logs live in the private directory alongside the SQLite database.

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

1. A review is a fresh, persisted, read-only Codex conversation in a detached snapshot.
   Persisting the reviewer retains its identity and audit history; it never
   reuses the original worker's context.
   It returns schema-validated `pass`, `fix_required`, `retry` or `needs_decision`.
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
   limited by Codex's workspace sandbox; approval and user-input requests
   are escalated rather than fabricated.
4. The four existing gate result checks must report **success** for the current
   PR head, from the GitHub Actions app (PR workflows execute the test merge,
   but their check runs are attached to the head SHA). Missing, pending,
   skipped, neutral and untrusted-source results never satisfy this test.
   GitHub additionally enforces current approvals and review-thread resolution.
5. A stale branch receives an ordinary merge commit from current main, local
   validation and a push, followed by fresh review and PR CI. Conflicts go to
   the worker. The merge API receives the exact reviewed head SHA. Effective
   branch rules must require all four checks from GitHub Actions and an
   up-to-date branch, with no merge queue. GitHub must confirm the merge;
   no deferred auto-merge request or admin bypass is used.

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
validation → fresh review → merge without publishing a review status gate.
No live PR is opened or merged by the tests.

Protocol references: [Codex App Server](https://learn.chatgpt.com/docs/app-server),
[GitHub protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).
