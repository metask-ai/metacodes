# Contributing to metacodes

Thanks for being here. metacodes is an agent harness kernel written in Zig, with
a Lean-checked governance layer, a graph memory and a stable C ABI. Few
projects put systems programming, formal methods and agent design in one
codebase; if any of those is your thing, there is a piece here for you.

The project is MIT-licensed, maintained by the team at
[Metask](https://app.metask-ai.com) whose products run on it, and pre-1.0:
interfaces still move, and good ideas still change the design.

## Where to start

Pick the row that matches what you like doing. Each one is a real gap, not a
make-work list.

| You like… | Start here | Good first contributions |
|---|---|---|
| Systems programming in Zig | [doc/CORE_REFERENCE.md](doc/CORE_REFERENCE.md), `packages/coding/src/core/`, `packages/coding/src/tools/` | Tool edge cases, error messages, Windows/Linux portability fixes, allocation audits on hot paths |
| Embedding and language bindings | [doc/API.md](doc/API.md), [sdk/README.md](sdk/README.md), [sdk/python](sdk/python/README.md), [sdk/node](sdk/node/README.md) | A Go binding; the Windows port of the Node addon; wrapping Skills, MCP, checkpoints and goals in the Python and Node packages; a 30-line "hello agent" in C |
| Formal methods and Lean (experimental) | [control-plane/README.md](control-plane/README.md), `control-plane/lean/` | New rule obligations, counterexamples that break an existing rule, proof cleanup |
| Agent quality and evals | [doc/BENCHMARKS.md](doc/BENCHMARKS.md), [evals/README.md](evals/README.md) | Reproduce a benchmark failure offline, write a zero-cost regression fixture, analyze a Security-subset trajectory |
| Memory and knowledge graphs | [doc/MEMORY_SYSTEM_DESIGN.md](doc/MEMORY_SYSTEM_DESIGN.md), [doc/TINYKG_INTEGRATION.md](doc/TINYKG_INTEGRATION.md) | Recall quality probes, a Markdown-memory or vector-RAG comparison arm, degraded-mode UX |
| Models and providers | [doc/PROVIDER_OFFER_ARCHITECTURE.md](doc/PROVIDER_OFFER_ARCHITECTURE.md), `packages/ai/src/api/model_adapter.zig` | A model-family adapter, a local-model (Ollama, llama.cpp, vLLM) recipe, dialect conformance tests |
| Plugins and tools | [doc/PLUGIN_ARCHITECTURE.md](doc/PLUGIN_ARCHITECTURE.md), [doc/PLUGIN_PROCESS_PROTOCOL.md](doc/PLUGIN_PROCESS_PROTOCOL.md) | A process plugin in any language, a plugin template, a sample Skill pack |
| Sandboxing and security | `packages/guard/src/sandbox/`, `packages/guard/src/permission/`, [SECURITY.md](SECURITY.md) | A Windows sandbox backend, per-host network filtering, protected-path coverage, permission-rule fuzzing |
| Docs and translation | [doc/README.md](doc/README.md) | Tutorials, diagrams, keeping [README.zh-CN.md](README.zh-CN.md) and the English README in step |

Issues labelled
[`good first issue`](https://github.com/metask-ai/metacodes/labels/good%20first%20issue)
and [`help wanted`](https://github.com/metask-ai/metacodes/labels/help%20wanted)
are claimed by commenting on them. For anything larger than a bug fix, open a
[discussion](https://github.com/metask-ai/metacodes/discussions) or an issue
first so we can agree on the boundary before you write code.

## Initial development setup

Start the [PR watcher](.github/pr-loop.py) as part of setting up your
development environment, before submitting your first PR. You need Python
3.9+, Git, authenticated GitHub CLI (`gh`) and Codex CLI, and `dx` configured
for the worker checkout. The original Codex worker thread must be accessible
to the local App Server and handed over idle when the watcher needs to repair
the PR. See the [PR workflow guide](doc/PR_AGENT_LOOP.md) for prerequisites.

From the repository root, start one watcher in a dedicated terminal:

```sh
python3 .github/pr-loop.py run
```

**Keep this process running while your PRs are being delivered.** It is a
foreground process: closing the terminal, pressing Ctrl+C or shutting down
the computer stops it. Restart it when you resume development; PR bindings
and progress persist locally. This script lives under `.github/` and runs
on your Mac. The loop polls registered PRs every sixty seconds; GitHub CI
runs on GitHub independently. Local review and repair
pause while the watcher is stopped or your Mac is asleep or offline.

For each task, push its branch and register the PR with its original worker
thread and worktree. Use `submit` to create the PR in the mother repository
and register it together:

```sh
python3 .github/pr-loop.py submit \
  --worktree "$TASK_WORKTREE" --thread "$TASK_THREAD_ID" \
  --head "$GITHUB_OWNER:$TASK_BRANCH" \
  --title "fix: describe the change" --body-file "$PR_BODY_FILE"
```

The target defaults to `metask-ai/metacodes`, including when your push remote
is a fork. If you already created the PR another way, register it with:

```sh
python3 .github/pr-loop.py bind --pr "$PR_NUMBER" \
  --worktree "$TASK_WORKTREE" --thread "$TASK_THREAD_ID"
```

`submit` and `bind` register work for the running watcher; they do not start
it. The watcher reviews each revision in an independent read-only Codex
conversation, returns blocking findings or CI failures to the original
worker, checkpoints repairs and validates them through `dx zig build gate:pr`
on devbox before pushing. It merges current main into a stale branch, validates
and pushes that revision, and repeats review and PR CI. When both pass, it
requests an exact-head merge under strict up-to-date branch protection.
Only registered PRs participate. Ordinary main pushes do not repeat PR CI;
Linux ARM64, Intel macOS and Windows ARM64 cross-build coverage runs at release
time ([CI design](doc/CI_DESIGN.md#3-pr-only-validation-and-merge-policy)).

When a decision or additional permission is needed, or a configured limit is
reached, the loop pauses and notifies you locally. Check progress and answer:

```sh
python3 .github/pr-loop.py status
python3 .github/pr-loop.py answer --pr "$PR_NUMBER" --text "Your decision"
```

The [PR workflow guide](doc/PR_AGENT_LOOP.md) covers invocation limits,
recovery and state storage. Model calls use your existing Codex account and
incur its normal usage; the controller does not upload credentials to CI.

## Your first build

You need Zig 0.16.0 (the version in `build.zig.zon`), Python 3.9 or newer with
PyYAML (`python3 -m pip install -r requirements-dev.txt`), the pinned linters
(`python3 -m pip install -r requirements-lint.txt`), and Git. Lean (elan) is
optional: without it the kernel-gated tests skip and say so.

```sh
git clone https://github.com/metask-ai/metacodes.git
cd metacodes
zig build dev                                   # fastest edit loop: Debug app only
./zig-out/bin/metacodes --help
zig build test:lib -Dtfilter="max_turns"        # iterate on the tests you touch
zig build gate:static                           # the source-level guards, in seconds
python3 scripts/lint.py                         # ruff, shellcheck and actionlint
zig build gate:pr                               # the full pre-submit gate
```

A filtered run compiles only the selected tests, so finish with the unfiltered
gate. [tests/README.md](tests/README.md) maps the test layers to build steps;
[doc/GETTING_STARTED.md](doc/GETTING_STARTED.md) covers platforms, Lean
kernels and Windows.

## How changes get accepted

Read [AGENTS.md](AGENTS.md) once; it is short and it is the contract every
reviewer (human or agent) applies. The ideas behind it:

- **Declaration = wiring = evidence.** A new field, flag or tool parameter is
  done when a component or integration test shows it changing the real
  request, child process, stored state or host-visible result. A field that is
  parsed but never used is a bug, not a feature.
- **Test both sides.** Add the failure and the rejected illegal state, not
  only the happy path.
- **The kernel stays fixed.** Plugins and hosts can add tools, providers, UIs
  and narrower policy. They cannot replace the agent loop or loosen
  permissions, sandbox, budgets, formal verdicts, TinyKG admission or the
  artifact store. A change that needs to cross that line starts as a
  discussion.
- **Prompt bytes are a cache contract.** Say in the pull request whether the
  bytes sent to the model are unchanged, intentionally changed (and tested),
  or unknown. Timestamps, plugin paths, journals and random ids never enter
  prompts.
- **Public interfaces move together.** An API, ABI or protocol change updates
  [doc/API.md](doc/API.md), the normative protocol document, the SDK fixtures
  and an end-to-end consumer test in the same pull request.

## Pull requests

- Register your PR through `submit` or `bind` and keep the watcher running
  as described in [Initial development setup](#initial-development-setup).
- Keep each pull request to one outcome and describe it from the user's side.
- Run `zig build gate:pr` and paste the tail of its `Build Summary` into the
  pull request template. Judge a build by its exit code, not by the word
  `failed` in step output ([AGENTS.md](AGENTS.md) explains why).
- No credentials, personal absolute paths, generated benchmark runs, local
  stores or compiled binaries. The manifest-pinned TinyKG and ripgrep assets
  under `vendor/` are the only binaries in the tree.
- TinyKG is consumed as a pinned binary. Do not add its source, a
  download-on-build step, a `PATH` lookup or a sibling-checkout fallback; the
  audit procedure is in [doc/TINYKG_INTEGRATION.md](doc/TINYKG_INTEGRATION.md).
- Paid, model-backed evaluations never run in ordinary pull requests or CI.
  They need maintainer authorization, a dollar cap and the durable budget
  journal ([doc/BENCHMARKS.md](doc/BENCHMARKS.md) §5).

CI runs the same gates on Linux, macOS and Windows. Pull requests from first-time
contributors wait for a maintainer to approve the workflow run; that is a
GitHub setting, not a judgement on your change.

## Getting help

- Questions and design ideas: [GitHub Discussions](https://github.com/metask-ai/metacodes/discussions).
- Reproducible bugs: an issue with the commit, Zig version, OS/architecture,
  provider kind and sanitized logs ([SUPPORT.md](SUPPORT.md)).
- Vulnerabilities: privately, as described in [SECURITY.md](SECURITY.md).
  Never in a public issue.

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md). Project
decisions are made as described in [GOVERNANCE.md](GOVERNANCE.md).

## License

metacodes is released under the [MIT License](LICENSE). By submitting a
contribution you agree that it is licensed under the same terms.
