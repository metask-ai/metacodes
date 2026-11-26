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
| Systems programming in Zig | [doc/CORE_REFERENCE.md](doc/CORE_REFERENCE.md), `src/core/`, `src/tools/` | Tool edge cases, error messages, Windows/Linux portability fixes, allocation audits on hot paths |
| Embedding and language bindings | [doc/API.md](doc/API.md), [sdk/README.md](sdk/README.md), [sdk/python](sdk/python/README.md), [sdk/node](sdk/node/README.md) | A Go binding; the Windows port of the Node addon; wrapping Skills, MCP, checkpoints and goals in the Python and Node packages; a 30-line "hello agent" in C |
| Formal methods and Lean (experimental) | [control-plane/README.md](control-plane/README.md), `control-plane/lean/` | New rule obligations, counterexamples that break an existing rule, proof cleanup |
| Agent quality and evals | [doc/BENCHMARKS.md](doc/BENCHMARKS.md), [evals/README.md](evals/README.md) | Reproduce a benchmark failure offline, write a zero-cost regression fixture, analyze a Security-subset trajectory |
| Memory and knowledge graphs | [doc/MEMORY_SYSTEM_DESIGN.md](doc/MEMORY_SYSTEM_DESIGN.md), [doc/TINYKG_INTEGRATION.md](doc/TINYKG_INTEGRATION.md) | Recall quality probes, a Markdown-memory or vector-RAG comparison arm, degraded-mode UX |
| Models and providers | [doc/PROVIDER_OFFER_ARCHITECTURE.md](doc/PROVIDER_OFFER_ARCHITECTURE.md), `src/api/model_adapter.zig` | A model-family adapter, a local-model (Ollama, llama.cpp, vLLM) recipe, dialect conformance tests |
| Plugins and tools | [doc/PLUGIN_ARCHITECTURE.md](doc/PLUGIN_ARCHITECTURE.md), [doc/PLUGIN_PROCESS_PROTOCOL.md](doc/PLUGIN_PROCESS_PROTOCOL.md) | A process plugin in any language, a plugin template, a sample Skill pack |
| Sandboxing and security | `src/sandbox/`, `src/permission/`, [SECURITY.md](SECURITY.md) | A Windows sandbox backend, per-host network filtering, protected-path coverage, permission-rule fuzzing |
| Docs and translation | [doc/README.md](doc/README.md) | Tutorials, diagrams, keeping [README.zh-CN.md](README.zh-CN.md) and the English README in step |

Issues labelled
[`good first issue`](https://github.com/metask-ai/metacodes/labels/good%20first%20issue)
and [`help wanted`](https://github.com/metask-ai/metacodes/labels/help%20wanted)
are claimed by commenting on them. For anything larger than a bug fix, open a
[discussion](https://github.com/metask-ai/metacodes/discussions) or an issue
first so we can agree on the boundary before you write code.

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

- Open the PR against `metask-ai/metacodes` and request independent review.
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
