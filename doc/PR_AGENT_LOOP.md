# PR review and repair loop

`python3 -m tools.pr_loop` is an opt-in delivery controller for PRs submitted
to **metask-ai/metacodes**. It registers a PR with its original Codex thread
and worktree, independently reviews each revision, returns actionable feedback
to that thread, validates and pushes repairs, and requests admission to the
upstream merge queue. Decisions and interrupted writes stop in a durable
`needs_decision` state. Ordinary review findings, failing CI and failed local
validation return to the worker automatically, within the registered limits.

This is contributor tooling, not a metacodes runtime API. It runs on the
contributor's Mac; local builds, tests and gates run on devbox through `dx`.
The existing GitHub-hosted CI and `Protect main` rules remain the final merge
authority. See [CI design](CI_DESIGN.md) for the four required result checks
and the existing `merge_group` wiring.

## Prerequisites

- Python 3.9+, Git, authenticated GitHub CLI (`gh`) and Codex CLI with the
  stdio App Server protocol. No additional Python packages are required.
- An already pushed PR branch in a clean, dedicated worktree. Its configured
  push remote must point to the PR's head repository. The target is upstream
  `metask-ai/metacodes`, even when that remote is a contributor's fork.
- A persisted Codex thread accessible to the local App Server, whose `cwd`
  is that worktree. The worker must be idle before it receives repair work.
  A desktop or remote chat is usable only if that host exposes the same
  thread to this App Server; an arbitrary UI chat ID is not sufficient.
- `dx` configured for the worker checkout. The controller always executes
  `dx zig build gate:pr` before pushing an automatic repair. It saves local
  checkpoint commits first: some evaluation tests materialize committed HEAD
  and intentionally refuse dirty pinned inputs. A failed checkpoint is never
  pushed; its validation output goes back to the original worker.
- GitHub permission to publish commit statuses, push the head branch and
  enqueue the PR upstream. No admin bypass is used or requested.

Codex uses its existing local authentication. The controller does not copy
credentials to GitHub Actions, read auth tokens or write secrets to PR bodies.
Agent calls incur the signed-in account's normal usage. Defaults allow five
repair rounds, sixteen total agent calls (including reviews) and thirty
minutes per agent or gate invocation. These are invocation and time bounds,
not a dollar or token spending cap.

## New PR entry point

From the checkout containing this tooling, create a PR **in the mother
repository** and bind it in one command. Supply your own branch and thread ID:

```sh
python3 -m tools.pr_loop submit \
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
python3 -m tools.pr_loop bind \
  --repo metask-ai/metacodes --pr "$PR_NUMBER" \
  --worktree "$TASK_WORKTREE" --thread "$TASK_THREAD_ID"
```

Registration is idempotent for an identical binding. An active worktree or
thread cannot own two PRs. The controller processes only registered PRs; it
does not adopt unrelated open PRs or grant public PR authors execution access
to the local host.

Start the watcher on the Mac, from the tooling checkout:

```sh
python3 -m tools.pr_loop run
```

Keep it in a persistent terminal or your service supervisor. The watcher polls
registered PRs every sixty seconds, so PR creation and subsequent pushes
trigger work without a public webhook receiver or provider secrets in CI.
Use `run --once` for one reconciliation pass, or `run --interval 30` to change
the polling period. A second watcher using the same state database is refused.
New PR registration remains available while another PR is being processed.
Answer commands should be run between reconciliation passes.

## Decisions and recovery

```sh
python3 -m tools.pr_loop status
python3 -m tools.pr_loop answer --pr "$PR_NUMBER" \
  --text "Keep compatibility with the existing response; add an optional field."
```

Only entering `needs_decision` emits a notification (stderr and a local macOS
notification). Repeated polling stays quiet. The reason is durable even if
desktop notifications are unavailable. A response becomes context for the
next review or worker turn. Partially edited files are preserved for that
continuation. No automatic reset, force push or deletion of worker changes is
performed.

Budget consumption persists across commits and restarts. Extending it requires
an explicit answer, for example:

```sh
python3 -m tools.pr_loop answer --pr "$PR_NUMBER" \
  --text "Continue the same task for two more repair attempts." \
  --extra-rounds 2 --extra-agent-runs 4
```

The default SQLite database is
`~/.local/state/metacodes/pr-loop.sqlite3`. Use the global `--state PATH`
option before the subcommand to select another database. Keep it outside the
repository: it contains local paths, thread IDs, review evidence and decisions.
Its event log records state transitions. A crash during review, repair,
validation, push or enqueue is escalated on restart instead of replaying an
operation with an uncertain outcome. Inspect the worktree and PR before
answering; an answer does not automatically reconcile a divergent checkout.

## Admission contract

1. A review is a fresh, read-only Codex conversation in a detached snapshot.
   It returns schema-validated `pass`, `fix_required` or `needs_decision`.
   A passing report cannot contain unresolved findings or a question.
2. Reports are bound to both head and base SHA. A changed revision invalidates
   them; the controller rechecks the revision after review, repair and local
   validation, and immediately before enqueueing.
3. The bound worker thread is resumed by ID, never by `--last`. It must be
   handed over idle and must not be driven concurrently by another host.
   It edits the
   original checkout. The controller owns validation, commit, ordinary push
   and merge-queue admission. Policy, workflow and controller edits require
   a decision. The worker's network is disabled; the controller executes the
   devbox gate and returns failures as feedback. Writable tool access is limited by Codex's workspace sandbox;
   approval and user-input requests are escalated rather than fabricated.
4. The four existing gate result checks must report **success** for the current
   PR head, from the GitHub Actions app (PR workflows execute the test merge,
   but their check runs are attached to the head SHA). Missing, pending,
   skipped, neutral and untrusted-source results never satisfy this test.
   GitHub additionally enforces current approvals and review-thread resolution.
5. Admission uses `enqueuePullRequest` with `expectedHeadOid`. It never creates
   a deferred auto-merge request or falls back to an admin/direct merge.
   Being queued is not being merged; the watcher waits for GitHub's actual
   merged state. Queue ejection returns the problem to the worker.

`agent/review` is a contributor-visible commit status. It is not added to the
repository's required checks by this change; the local controller enforces it
for its own admissions. Repository-wide mandatory agent review, including
manual merges or admissions by other actors, would need a separately deployed
trusted reviewer and a required check that also reports on merge groups.

## Verification

```sh
dx zig build test:pr-loop
```

This suite also runs in `test:units` on every PR. It uses real temporary Git
repositories and pushes to a local bare repository, a fake stdio Codex process,
and recorded GitHub API requests. It proves review → original-thread repair →
validation → push → fresh review → exact-head enqueue → observed merge, without
provider calls. It also exercises stale review rejection, CI failures, busy
workers, decision recovery, invocation limits, policy edits and interrupted
operations. No live PR is opened or merged by the tests.

Protocol references: [Codex App Server](https://learn.chatgpt.com/docs/app-server),
[GitHub merge queue](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/merging-a-pull-request-with-a-merge-queue).
