# Harbor dataset adapters

Benchmarks that Harbor 0.26 has no adapter for, written for the
`metacodes bench` workbench. Each module turns a pinned public dataset into
Harbor task directories that `harbor run -p <dataset dir>` runs and
`harbor run -p <dataset dir> -i <task id>` filters (the `-i` patterns match
task directory names; Harbor 0.26 `src/harbor/cli/jobs.py`,
`src/harbor/models/job/config.py`).

| Module | Suite id | Category | Tasks | Grading (reward 1 iff) |
|---|---|---|---|---|
| `humaneval.py` | `humaneval` | 代码生成 | 164 | the dataset's `check(candidate)` passes |
| `mbpp.py` | `mbpp` | 基础编程 | 500 (test split, ids 11-510) | the three `test_list` asserts pass |
| `mbpp_sanitized.py` | `mbpp-sanitized` | 基础编程 | 257 (test split) | `test_imports` + the `test_list` asserts pass |
| `alfworld.py` | `alfworld` | 交互规划 | 134 (valid_unseen) | the environment's `won` flag within 50 actions |
| `searchqa.py` | `searchqa` | 问答 | 200 (pinned test subset) | normalised exact match (EM = 1) |
| `livemath.py` | `livemath` | 数学推理 | v202412 English sets | deterministic answer equivalence |

## Contract

The catalog (`scripts/eval/harbor/suites`, `ADAPTER_SUITES`) owns each
suite's id and category; the suite id differs from the module name only for
`mbpp-sanitized` (`mbpp_sanitized.py`). Each module exposes:

- `SUITE_ID` (the catalog id) and `SUITE`: `name`, `description` (Chinese),
  `default_tasks`, `max_tasks` (<= 200), `max_concurrency` (optional cap,
  none by default), plus an informational `arch` the catalog passes through (`arch` in
  `GET /api/workbench` suites, shown on the 新建评测 task list).
- `prepare(dest) -> Path`: `dest` is the dataset directory
  (`<state>/bench/datasets/<suite id>`); downloads the pinned sources into
  `dest/.cache/`, writes the task directories as children of `dest` and
  returns `dest`. A complete dataset is recognised by its marker
  (`dest/.metacodes-dataset.json`: suite, fingerprint of pins and generator
  sources, per-task tree SHA-256) and returned without network access. A
  damaged or outdated dataset is rebuilt from the cache in a scratch
  directory; the marker is written last.
- `tasks(dataset) -> list[str]`: the task directory names.
- `livemath.check(ctx)`: reports the missing Hugging Face token.

Task ids match `[A-Za-z0-9][A-Za-z0-9._-]*` (no glob characters). Python
3.9, standard library only; every file here is embedded in the
`metacodes bench` binary through `scripts/bench_assets.zig`.

## Task shape

All tasks use Harbor's task schema 1.4 (`instruction.md`, `task.toml`,
`environment/Dockerfile`, `solution/solve.sh`, `tests/test.sh`) with a
**separate verifier** (`[verifier] environment_mode = "separate"`), as in
Harbor's `examples/tasks/sidecar-artifacts` and
`examples/tasks/secure-python-worker`:

- The agent works in an image built from `environment/`, which holds no
  tests and no gold answers. The agent container keeps public network so the
  agent can reach its model provider.
- What is graded is declared in `artifacts` (`/app/solution.py`,
  `/app/answer.txt`, or the ALFWorld sidecar's episode record). Harbor
  copies only those files into a fresh verifier container built from
  `tests/Dockerfile`, which has **no network** and contains the grader,
  `spec.json` (hidden tests / gold answer) and `test.sh`. The reward (0 or 1)
  is written to `/logs/verifier/reward.txt`; details go to
  `/logs/verifier/grade.json`.
- `solution/solve.sh` is the oracle: Harbor's oracle agent runs it to prove
  task + verifier end to end.
- Base images are pinned by multi-arch index digest:
  `python:3.12-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df`
  (agent and verifiers) and
  `python:3.10-slim-bookworm@sha256:5be5aaecb962a41567bc8041f1e9e3432cb085b037fe057f9a562630b2e4b370`
  (ALFWorld sidecar, forced `linux/amd64`).

Graders (`graders/`) are deterministic and offline. The code grader never
lets the tests share an interpreter with the submission (the reference
HumanEval/MBPP harnesses do, which lets a submission forge a pass): the
submission runs as uid 65534 in one process and serves calls over a pipe;
the dataset's tests run as uid 65533 in another process that calls it,
decodes replies as plain data only (anything else is an opaque handle equal
only to itself) and alone reports the pass. Both have time, memory and file
size limits; the hidden tests (`spec.json`, mode 0600) are root-only, and
every process under either uid is killed before the root grader writes
`reward.txt` (threat model in the `code_grader.py` docstring).

## Sources, pins and licenses

| Suite | Source (immutable revision) | Content pin | License |
|---|---|---|---|
| humaneval | `openai/human-eval@463c980b59e818ace59f6f9803cd92c749ceae61` `data/HumanEval.jsonl.gz` | SHA-256 `b796127e635a67f93fb35c04f4cb03cf06f38c8072ee7cee8833d7bee06979ef`, 44,877 B | MIT |
| mbpp | `google-research/google-research@f46ca8374b4cddef97ca4208ad986049d74d296a` `mbpp/mbpp.jsonl` | SHA-256 `ccf64ceae9c5403bf50a044cb6d505bfd2a2963ee58338ba268fd65beab92a9f`, 563,743 B | CC-BY-4.0 (data) |
| mbpp_sanitized | same commit, `mbpp/sanitized-mbpp.json` | SHA-256 `ca95deaa9a01ef0a6f439f88bcf0dd3db3563d22f22aad6cae04ebb9a8d8c8e9`, 255,053 B | CC-BY-4.0 (data) |
| alfworld | `alfworld/alfworld` release `0.4.0` (commit `beadec4de1de2485e8a260138a9ba2ac27a8865a`) asset `json_2.1.2_tw-pddl.zip` | SHA-256 `eea90499df27b9cb3147d1d1927264146d38194b575e25f70a82875545742dcb`, 36,493,542 B | MIT |
| searchqa | HF `kyunghyuncho/search_qa@06907e45883b7cae435453b65d598447039fde79` `data/train_test_val/test.zip` | 200-member subset SHA-256 (`searchqa.SUBSET_SHA256`), per-member CRC-32 | not stated ("unknown"); Jeopardy! clues from J! Archive, Google snippets: research evaluation only |
| livemath | HF `opencompass/LiveMathBench@ea05b95ab431f3ef3900ce86f864451cf5bcd699` `202412/{AMC,CCEE,CNMO,WLPMC}_en.jsonl` | git blob SHA-1 + size per file (see below) | CC-BY-4.0, gated: the gate asks for agreement to non-commercial use |

Every download is verified before use and deleted on mismatch
(`SourceIntegrityError`); nothing is fetched at build time.

Packages installed into task images at image build time on the execution
host: the ALFWorld sidecar installs `alfworld==0.4.2`, `textworld==1.6.2`,
`fast-downward-textworld==20.6.4` and `spacy==3.7.5` from PyPI (versions
pinned; transitive dependencies are resolved by pip).

## Per-benchmark notes

**HumanEval / MBPP.** The agent writes a complete module to
`/app/solution.py`. HumanEval follows the reference harness (prompt, then
completion, then `check(entry_point)`): the prompt runs before the solution
in the same namespace, so a solution may use the prompt's helpers
(HumanEval/32 `poly`, /38 `encode_cyclic`, /50 `encode_shift`) or redefine
them. MBPP runs `test_setup_code` after the solution, and the asserts reach
only the names the reference code or setup binds. MBPP instructions use the
paper's prompt, which shows the three asserts that are graded; `challenge_test_list` is not used, as in the
reference evaluation. Two MBPP references (tasks 180 and 493) compare floats
exactly; they pass on Linux/glibc but not with macOS libm, so check them in
the Docker oracle run.

**ALFWorld.** The game runs in an `alfworld-env` sidecar
(`alfworld_env/server.py`); the agent plays through the `alfworld` CLI
(`alfworld_env/alfworld_cli.py`) with a budget of 50 actions. The sidecar is
the only witness: it writes `/var/lib/alfworld/result.json` after every
action, Harbor's `[[verifier.collect]]` hook freezes it, and the verifier
reads the collected record (task id, game SHA-256, `won`, trajectory). The
oracle (`alfworld oracle <token>`, token only in `solution/` and the
sidecar) plays the PDDL planner's `policy_commands` through the same step
path. The sidecar is `linux/amd64` only.

**SearchQA.** 200 test questions chosen by SHA-256 of the member file name
(first 200 with an answer and a snippet), read from the 622 MB archive by
HTTP range requests. The clue, category and all snippets are in
`instruction.md`; the answer goes to `/app/answer.txt`. Reward 1 iff the
SQuAD-normalised answer equals the gold answer as given, the gold with its
parenthetical text left out ("(Ken) Lay" accepts "Ken Lay" and "Lay", not
"Ken"), or an alternate J! Archive marks ("cocoa (or chocolate)" accepts
"chocolate", "referred pain (referral accepted)" accepts "referral"); token
F1 is recorded in `grade.json` but awards nothing.

**LiveMath.** "LiveMath" is taken to be **LiveMathBench** (OpenCompass,
arXiv:2412.13147), release v202412, English: AMC_en, CCEE_en, CNMO_en,
WLPMC_en. v202505 is excluded because many of its gold answers are prose that
no deterministic grader can check. The dataset is gated on Hugging Face:
accept its terms and set `HF_TOKEN` (or `huggingface-cli login`) before
`prepare()`. Without access when this adapter was written, the files are
pinned by the git blob SHA-1 and size Hugging Face reports at the pinned
commit (fail-closed); `prepare()` records the SHA-256 it verified in the
dataset marker. Grading is deterministic and stricter than the authors' LLM
judge: equal normalised strings, equal numeric value (fractions, roots,
pi), equal tuples/intervals (same brackets, same order) or sets/lists (any
order), or the same choice letters.

## Checks

`scripts/eval/tests/test_harbor_dataset_adapters.py` builds every adapter from
small fixtures under `scripts/eval/fixtures/harbor_adapters/` (no network),
validates the task directories against the Harbor 0.26 schema, runs every
oracle and a wrong answer through the real graders, drives the ALFWorld
sidecar API and CLI over loopback with a scripted game, and checks
idempotency and fail-closed pins. Docker-only checks (image builds, Harbor's
oracle agent over every task, the real TextWorld sidecar in compose) need a
Docker host:

```sh
harbor run -p <state>/bench/datasets/<suite id> -a oracle -n 4
```
