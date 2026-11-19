# Local configuration: `.env` in the state root

You can use metacodes with your own provider key instead of a Metask sign-in.
Put the key in one file of your install, `.env` in its state root, and start
metacodes again. Nothing goes into your shell profile and nothing into a
project directory. This page covers where the file is, what it may contain,
and how metacodes decides which provider to use. [PROVIDERS.md](PROVIDERS.md)
covers every way to give metacodes a model: a Metask account, a vendor's key
pasted with `metacodes login --provider <id>`, and a model API of your own
(`metacodes providers add`).

- [Where the file is](#where-the-file-is)
- [Writing the file](#writing-the-file)
- [Names it accepts](#names-it-accepts)
- [Which provider and model are used](#which-provider-and-model-are-used)
- [Presets](#presets)
- [What the file cannot set](#what-the-file-cannot-set)
- [Checking it](#checking-it)

## Where the file is

Every install has a state root of its own: the directory that also holds
`oauth/metask.json` (the Metask sign-in), `auth.json` and `config.json`. The
file is `.env` in it.

| Install | File |
|---|---|
| Release, installed with `scripts/install.sh` | `~/.local/opt/metacodes/state/.env` |
| Development install, `scripts/install.sh --dev` | `~/.local/opt/metacodes-dev/state/.env` (a linked worktree: `~/.local/opt/metacodes-dev-<worktree directory>/state/.env`) |
| A build run from a checkout, or an install older than install records | `~/.metacodes/.env` |
| `--state-dir <dir>`, or `METACODES_HOME=<dir>` | `<dir>/.env` |

Side-by-side installs keep separate files: a key in the release's file is not
seen by `metacodes-dev`, and the other way round.

`metacodes doctor` shows the state root and the file. `metacodes install` and
`metacodes update` write a template, `.env.example`, beside it, with one line
for every built-in provider; they rewrite the template on every install and
upgrade and never create or change `.env`.

```sh
cd ~/.local/opt/metacodes/state
cp .env.example .env
chmod 600 .env
```

metacodes reads `.env` when it starts, so start it again after an edit.

**Only this file is read.** metacodes never reads a `.env` in the working
directory or a repository, or anywhere else: any repository you clone can ship
a `.env`, and reading it would let that repository choose which provider your
session uses and with which key.

## Writing the file

One `NAME=value` per line:

```sh
# My DeepSeek key, for metacodes
DEEPSEEK_API_KEY=sk-...
METACODES_PROVIDER=deepseek
METACODES_MODEL=deepseek-v4-pro
```

- Blank lines and lines starting with `#` are skipped. An unquoted value ends
  at a `#` that follows a space: `KEY=value # note`.
- `export NAME=value` is accepted, so the file can also be sourced by a shell.
- Spaces around the name and the `=` are ignored.
- `'single quotes'` keep the value exactly as written. In `"double quotes"`
  only `\"`, `\\` and `\n` are escapes. `$NAME` is never expanded.
- Windows line ends (CRLF) are fine.
- An empty value (`NAME=`) is the same as not setting the name.
- If a name appears twice, the later line wins.
- A line that is none of the above is skipped and reported by its line
  number (never its content).

The file holds secrets: keep it readable by you only (`chmod 600`).
`metacodes doctor` warns when other users can open it.

## Names it accepts

**Provider keys.** Each built-in provider reads its key from these names (the
first one is the one to use; the others are accepted too):

| Provider (`METACODES_PROVIDER`) | Key |
|---|---|
| DeepSeek (`deepseek`) | `DEEPSEEK_API_KEY` |
| Kimi Code subscription (`kimi-code`) | `KIMI_CODE_API_KEY`, `KIMI_API_KEY` |
| Moonshot Kimi open platform (`kimi`) | `MOONSHOT_API_KEY` |
| Z.AI GLM Coding Plan (`zai-coding-plan`) | `ZAI_API_KEY`, `GLM_API_KEY`, `Z_AI_API_KEY` |
| OpenAI (`openai`) | `OPENAI_API_KEY` |
| Google Gemini (`gemini`) | `GEMINI_API_KEY`, `GOOGLE_API_KEY` |
| Alibaba Qwen (`qwen`) | `DASHSCOPE_API_KEY` |
| MiniMax (`minimax`) | `MINIMAX_API_KEY` |
| Amazon Bedrock (`bedrock`) | `AWS_BEARER_TOKEN_BEDROCK` (a Bedrock API key) |
| Metask (`metask`) | `METASK_API_KEY` (see [the order below](#which-provider-and-model-are-used): it counts as a Metask sign-in unless the file names another provider) |

A provider you define in `config.json` (`custom_providers`: written by
`metacodes providers add`, see [PROVIDERS.md](PROVIDERS.md#a-model-api-of-your-own),
or by hand, see [User-defined providers](PROVIDER_OFFER_ARCHITECTURE.md#user-defined-providers))
adds the names in its `env_aliases` — `providers add --key-env <NAME>` writes
one — and the variables `config.json` names
elsewhere are accepted too: `providers.<id>.credentials[].env` (a
[credential pool](PROVIDER_OFFER_ARCHITECTURE.md#credential-pools)) and
`provider_catalogs.<id>.credential_env`. These two are read where that pool or
catalog is used; they never choose a provider by themselves, so a file holding
only a pool variable still needs `METACODES_PROVIDER` or a provider key.

**Choosing.** `METACODES_PROVIDER` names the provider, by its id or one of its
aliases as `--provider` takes it. `METACODES_MODEL` names that provider's model,
as `--model` does; without it the provider's default model is used.
`METACODES_PRESET` names one of your [presets](#presets) instead, and comes
before `METACODES_PROVIDER` in the same file. In a session, `/model` changes
the model and the reasoning effort; the context length follows the model
chosen. The level the session runs with, `none` included, starts selected;
with none set, a DeepSeek model starts at `high`, the level DeepSeek uses
when a request names none, and a pick sends it by name.

One file holds the keys of as many providers as you use: each key is read
when its provider is chosen, by `--provider`, by `/model`, or by a default
you stored there. Without `METACODES_PROVIDER` the file chooses none of
them; [what a start does then](#which-provider-and-model-are-used).

Any other name is ignored, with one warning that lists the ignored names and
never their values. Only names written like variable names (capital letters,
digits and `_`) are listed: any other ignored line is reported by its line
number alone, since it may be part of a secret (a base64 line of a pasted PEM
key can end in `=` and look like `NAME=`). While the terminal UI is running the
warning goes to the log only; `metacodes doctor` always shows it.

Examples, one provider each:

```sh
# Kimi Code subscription (the key from the Kimi Code console)
KIMI_CODE_API_KEY=sk-kimi-...
METACODES_MODEL=k3.1-pro

# Z.AI GLM Coding Plan (a Coding Plan key, not a standard API key)
ZAI_API_KEY=...
METACODES_MODEL=glm-5.3

# OpenAI
OPENAI_API_KEY=sk-...
METACODES_MODEL=gpt-6.1-sol

# Google Gemini
GEMINI_API_KEY=...

# Moonshot open platform
MOONSHOT_API_KEY=sk-...

# Alibaba Qwen (DashScope / Bailian)
DASHSCOPE_API_KEY=sk-...

# MiniMax
MINIMAX_API_KEY=...

# Amazon Bedrock
AWS_BEARER_TOKEN_BEDROCK=...
```

## Which provider and model are used

At start, metacodes takes the first of these that applies:

1. **Flags and the shell environment**: `--provider`, `--offer`, or
   `METACODES_PROVIDER` set in the shell. `--model` (or `METACODES_MODEL` in
   the shell) picks the model. A provider named this way and without a key
   is not replaced by another: the terminal UI opens without a model and
   names the variable it needs; `-p` stops with the same.
2. **A preset named at start**: `--preset <name>`, or `METACODES_PRESET` set
   in the shell (see [Presets](#presets)).
3. **The preset this directory remembers** (`directory_presets` in
   `config.json`).
4. **The default you chose in `/model`** (Tab, "use from now on"), kept in
   `config.json`. When its provider has no key (anymore), it is passed over
   for the steps below, and the start says so once.
5. **A Metask sign-in**: `--api-key`, `METASK_API_KEY` in the shell, a key in
   `auth.json`, or the Metask session `metacodes login` (or `/login`) stored
   in `oauth/metask.json`; a key comes before the session. `METASK_API_KEY` in this
   file counts too, unless the file's `METACODES_PROVIDER` names another
   provider: the provider the file names is its choice, and a Metask key
   beside it does not overrule that.
6. **What this file chooses**: its `METACODES_PRESET`, else its
   `METACODES_PROVIDER`, or, when it names neither, the one provider whose
   key the file holds.
7. **Nothing**: the terminal UI opens without a model. Its banner reads
   `not set — /login, or configure .env`, and a message you send is not sent:
   a red note says how to sign in or set up this file, and ↑ brings the
   message back once a model is set up. `-p`, `serve` and `--web` stop
   instead, with the same advice.

So `METACODES_PRESET`, `METACODES_PROVIDER` and `METACODES_MODEL` in the file
apply only when nothing above them decides: once you sign in to Metask (`/login`, or
`metacodes login`), the file's provider no longer takes over. Its keys still
work: a provider you choose with `--provider` or in `/model` reads its key
from the file. `/model` lists a provider only once its key is here (or in
the environment, or stored by `/login <provider>`); until then it is not
listed. When no provider is, `/model` says so and points to `/login` and to
this file, by its path. While the terminal UI starts on Metask instead of this
file's provider, it says so once under its banner (`.env configures DeepSeek;
the default is Metask. To use DeepSeek: /model, or /logout`). `/logout` signs you out of
Metask and switches the session to the provider this file configures
(`Switched to DeepSeek (from .env)`); later starts use it too.

`metacodes login status` shows this decision without starting anything: the
provider a plain start in the current directory uses, the step that decided,
and what each step holds (a variable's name, a file's path, a sign-in's
expiry; never a key or a token). It takes no flags: step 2 is what the shell
sets. It also names the providers' keys that are only in the shell, which
choose nothing:

```text
This start uses DeepSeek from /Users/you/.local/opt/metacodes/state/.env.
Level 6 of 7 decided; the first that applies wins:
  1 named at start: nothing (METACODES_PROVIDER is not set)
  2 preset named at start: nothing (METACODES_PRESET is not set)
  3 this directory (/Users/you/src/scratch): remembers no preset
  4 stored default: none
  5 Metask sign-in: no session
      /Users/you/.local/opt/metacodes/state/auth.json: not stored
      METASK_API_KEY: not set
> 6 /Users/you/.local/opt/metacodes/state/.env: read; DEEPSEEK_API_KEY; configures DeepSeek (the one provider whose key it holds)
  7 nothing: the TUI opens without a model; -p and the rest stop
Keys in the shell choose no provider: OPENAI_API_KEY (OpenAI). To use one: --provider <id>, or put it in /Users/you/.local/opt/metacodes/state/.env.
No secret was printed.
```

A file with keys of several providers and neither `METACODES_PRESET` nor
`METACODES_PROVIDER` chooses none, and metacodes does not guess. The terminal UI opens without a model,
as in step 7, and says once under its banner which providers the file has
keys for (`.env has keys for DeepSeek and OpenAI. Choose one with /model;
Tab there applies it to every future session.`); a message you send gets
the red note, which points to `/model` with the same names. A route you
choose there is this session's; press Tab first, to "from now on", and it
is stored as the default of step 4, so later starts use it without
asking, with its key still read from this file. `-p`, `serve` and
`--web` stop instead, listing the providers by id; add
`METACODES_PROVIDER=<id>` (or `METACODES_PRESET=<name>`) to the file, or
store a default in `/model` once. A `METASK_API_KEY` among them is the
exception: with no name in the file it is a Metask sign-in (step 5), so
that file starts on Metask.

An endpoint you set in the shell (`--base-url`, `METACODES_BASE_URL`) applies
to whichever provider is selected, the one this file configures included, as
it does with `--provider`: that provider's key goes to the address the shell
gives. Unset it when you use the file's provider directly.

A key that is only in your shell environment never selects a provider by
itself (`OPENAI_API_KEY` exported for another tool does not make metacodes
use OpenAI). Keys in this file were put there for metacodes, so they do.

**The shell wins over the file.** When a name is set in both, the shell's
value is used. For a provider with several key names, a key in the shell under
any of them means the file's keys for that provider are not read at all, so
the shell's `KIMI_API_KEY` and the file's `KIMI_CODE_API_KEY` are never seen
as a conflict. Two names of one provider holding different values in the
same place are refused as conflicting.

## Presets

A preset is a named setup kept in `config.json` in the state root, beside this
file: a route (provider, model, account) and its controls (the reasoning
effort). Keep several and switch with one flag; a directory can remember
which one it uses. Secrets stay where they are (this file, the shell, `/login`):
a preset names a route, never a key.

```json
{
  "presets": {
    "kimi": {
      "target": {"kind": "auto_route", "selector": "k3.1-pro"},
      "controls": {"reasoning_effort": {"text": "high"}}
    },
    "client-a": {
      "target": {"kind": "pinned_offer", "offer_id": "offer-0123456789abcdef0123456789abcdef"}
    }
  },
  "directory_presets": {
    "/Users/you/work/client-a": "client-a"
  }
}
```

Each preset has the shape `global_selection` (the `/model` default) has: a
`target`, either `auto_route` with a `selector` (a model id, as `--model`
takes it; it is resolved against every provider) or `pinned_offer` with an
`offer_id` (one exact route, its account included; `metacodes
--check-providers` lists every offer), and optional `controls`, each value
tagged (`{"text": "high"}`). A preset name is letters, digits, `.`, `_` and
`-`, starting with a letter or a digit.

**Choosing one.** `--preset <name>`, or `METACODES_PRESET=<name>` in the shell
(the flag wins), is step 2 above; `METACODES_PRESET` in this file is step 6,
like the file's other choices. A flag changes one field for that start only and
never edits the preset: `--model`, `--channel` and `--reasoning-effort`
replace the preset's model, channel and reasoning effort; `--provider` and
`--offer` name a route of their own (step 1), and the preset is not used. A
preset names its route as `--provider` would: when that provider has no key,
no other provider is used in its place. A resumed session (`--resume`) that
chose a route for itself in `/model` continues on that route, as before.

**Remembering one for a directory.** `directory_presets` maps a directory to a
preset by name, so editing the preset changes what every directory that names
it uses from the next start on. The directory is the git worktree root when you
start inside a repository (the nearest directory above holding `.git`), else
the directory itself, as `pwd -P` prints it; an entry written with a trailing
`/` or through a symlink matches too. Nothing is ever written into the
directory. For now you write these entries by hand; `metacodes login status`,
run in the directory, shows which one applies.

**A name that is not there.** A preset named at start, remembered by the
directory, or named in this file that `config.json` does not define makes
`-p`, `serve` and `--web` stop with exit code 2, listing the presets that are
defined. The terminal UI says so under its banner and starts as if the preset
had not been named. A preset whose entry is malformed makes `config.json`
unreadable (`InvalidPreset`, `InvalidPresetName`, `InvalidDirectoryPreset`),
which `metacodes --check-providers` reports.

## What the file cannot set

Request addresses are never read from it: `METACODES_BASE_URL`,
`METASK_GATEWAY_URL`, `METASK_SITE_URL`, `METACODES_KEY_CHECK_URL`,
`METACODES_KG_URL`, and any other name ending in `_URL`, even one that a
provider definition names. A file that could redirect requests could send
your key somewhere else. To use your own relay or endpoint, define it in
`config.json` as a [user-defined provider](PROVIDER_OFFER_ARCHITECTURE.md#user-defined-providers)
— `metacodes providers add <id> --base-url <url> --protocol <wire> --model <id>`
writes one ([PROVIDERS.md](PROVIDERS.md#a-model-api-of-your-own)) — where the
endpoint rules and `metacodes --check-providers` apply; its key can then live
in this file (`--key-env <NAME>`), or in its own key file
(`metacodes login --provider <id>`).

The file sets nothing else either: it is not loaded into the environment, so
tools and commands that metacodes runs do not see its values.

## Checking it

`metacodes doctor` reports the file's path, whether it was read, which names
are read from it and which are ignored, the line numbers it skipped, and
whether other users can open it. It never prints a value. `--json` puts the
same in a `local_config` object.

```text
Local configuration (.env)
  ✓ ~/.local/opt/metacodes/state/.env  read
    reads    DEEPSEEK_API_KEY, METACODES_PROVIDER
```

When no provider has a key, the terminal UI's note (and the error of `-p`,
`serve` and `--web`) names this install's file and the template beside it, and
links this page. Keys that are only in your shell are listed by name there,
never used: choose one of those providers in `/model` to use its key. When the
provider rejects the key (HTTP 401 or 403), the failed request ends by naming
the variable and this file: `DeepSeek rejected the API key. Check
DEEPSEEK_API_KEY in ~/.local/opt/metacodes/state/.env or your shell, then
restart.`
