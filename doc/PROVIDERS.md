# Providers: where metacodes gets its models

metacodes runs a model from one of three kinds of source. This page says how
to set each one up from the command line, where what you enter is stored, how
to check it, and what the common errors mean.

| Source | Who bills you | How you set it up |
|---|---|---|
| [A Metask account](#a-metask-account) | Metask | `metacodes login`, or `/login` in the terminal UI |
| [A built-in vendor](#a-built-in-vendor) (DeepSeek, OpenAI, Gemini, Qwen, …) | that vendor: a pay-as-you-go key, or a coding plan | `metacodes login --provider <id>` (or `/login <id>`) to paste a key (`openrouter` and `chatgpt-codex` sign in), or a key in `<state root>/.env` |
| [A model API of your own](#a-model-api-of-your-own) (a relay, a company gateway, Ollama or vLLM on this machine, a vendor's coding-plan address) | whoever runs it | `metacodes providers add …`, or `config.json` by hand |

Three commands, one job each:

- `metacodes login` and `/login` get a credential: they sign in, or take a
  key.
- `metacodes providers …` defines an endpoint of your own.
- `/model` chooses a model. It takes no key and signs in to nothing.

Everything below lives in your install's **state root**, which
`metacodes doctor` prints: `~/.local/opt/metacodes/state` for a release
install, `~/.local/opt/metacodes-dev/state` for a development one,
`~/.metacodes` for a build run from a checkout, or the directory
`--state-dir` names. Side-by-side installs keep separate state roots, so a
key stored in one is not seen by another.

- [A Metask account](#a-metask-account)
- [A built-in vendor](#a-built-in-vendor)
- [A model API of your own](#a-model-api-of-your-own)
  - [Adding one](#adding-one)
  - [Its key](#its-key)
  - [Asking which models it serves](#asking-which-models-it-serves)
  - [Changing, listing and removing](#changing-listing-and-removing)
  - [Examples](#examples)
  - [Common errors](#common-errors)
- [Which one a start uses](#which-one-a-start-uses)

## A Metask account

**Set it up.**

```sh
metacodes login                      # signs in in the browser, then asks for the model and reasoning level
metacodes login --provider metask    # the same with a short code you confirm on any device (SSH, no browser)
```

In the terminal UI, `/login` and `/login metask` do the same. A Metask API key
works too: `METASK_API_KEY` in your shell or in `<state root>/.env`, or
`metacodes login --api-key <key>`.

**Where it is stored.** `<state root>/oauth/metask.json` holds the session
and its refresh token; `<state root>/auth.json` holds the model and reasoning
level you chose, or a key from `login --api-key`. Both are readable by you
only (0600).

**Check it.** `metacodes login status` names the credential a plain start
uses and why (it never prints a key or a token); `metacodes doctor` checks
the state root and the files' permissions.

**Sign out.** `metacodes logout` (or `/logout`) revokes the session at Metask,
removes both files, and forgets a default model that was a Metask one. A
`METASK_API_KEY` left in your shell or `.env` is named, not removed.

### Using a manager's login on an SSH node

A manager signed in with `metacodes login` can provide model access to a named
SSH executor between jobs. The node can start its own ordinary conversations
and local Bench runs. Its provider talks to its loopback port through SSH.
The node verifies the manager's TLS certificate before sending a model request.
The manager and its running CLI share a refresh lock and read the latest
session before renewing it. Both account tokens stay on the manager.

On the manager, configure the node as an
[SSH executor](BENCH_WORKBENCH.md#execution-machines) and verify its SSH host
key. Start the share with a dedicated pairing file for this node. The
manager uses OpenSSL to create a private pairing file and an adjacent
`node-b.env.identity` directory on first use. Keep that directory on the
manager. It holds the TLS private key and its one-year certificate.
The node's SSH server must permit reverse forwarding to loopback
(`GatewayPorts no` or `clientspecified`).

```sh
metacodes bench share --executor node-b --peer-env node-b.env
```

In a second terminal, copy just the pairing file to B once with
`scp -p node-b.env node-b:manager-pair.env`, using B's SSH destination.
Use a version of Metacodes with certificate pairing on both machines.
Keep the share command running. It reconnects after an
SSH disconnect and uses port 18767 on the node by default. `--port` changes
that port. Ctrl-C closes the share.

On the node, add the single line from `manager-pair.env` to the private
`.env` of the install shown by `metacodes doctor`. Register the provider
once, using model ids available to the manager. Repeat `--model` for more
models. For a plain start on an install with several provider keys, select
`manager` as the default in `/model`.

```sh
model=glm-5.3-flash
metacodes providers add manager --display-name "Metask manager" \
  --base-url https://127.0.0.1:18767 --protocol anthropic_messages \
  --auth bearer --key-env MODEL_MANAGER_KEY --model "$model"
metacodes login status
metacodes
metacodes bench --auth provider --model "manager/$model"
```

The node can list models and make inference requests while the manager
provides access. During a disconnect the node checks the certificate on
each new connection before sending its pairing key or prompt. Signing out
on the manager prevents subsequent requests. If the authorization server moves the
session to a new model gateway during renewal, the manager saves the renewed
session. Restart the share and any manager conversation or Bench run bound to
the old gateway. The node can keep its pairing file.
To withdraw access from one node, stop its share. To pair it with a fresh
identity before its certificate expires, start the share with a new pairing
filename, copy the new pairing line to the node and restart its clients.

## A built-in vendor

metacodes ships these providers. Each reads its key from the variables in the
right-hand column, or from a key you stored with `login`:

| Id (`--provider`) | Vendor | Key variables |
|---|---|---|
| `deepseek` | DeepSeek | `DEEPSEEK_API_KEY` |
| `openai` | OpenAI (Platform API keys) | `OPENAI_API_KEY` |
| `gemini` | Google Gemini | `GEMINI_API_KEY`, `GOOGLE_API_KEY` |
| `qwen` | Alibaba Qwen (Model Studio, pay as you go) | `DASHSCOPE_API_KEY` |
| `minimax` | MiniMax | `MINIMAX_API_KEY` |
| `kimi` | Moonshot Kimi open platform | `MOONSHOT_API_KEY` |
| `kimi-code` | Kimi Code subscription | `KIMI_CODE_API_KEY`, `KIMI_API_KEY` |
| `zai-coding-plan` | Z.AI GLM Coding Plan | `ZAI_API_KEY`, `GLM_API_KEY`, `Z_AI_API_KEY` |
| `bedrock` | Amazon Bedrock | `AWS_BEARER_TOKEN_BEDROCK` |
| `openrouter` | OpenRouter | `OPENROUTER_API_KEY` |

**Two sign in instead.** `metacodes login --provider openrouter` (or `/login
openrouter`) signs in on OpenRouter in the browser (`--device-code`: on
another device), which creates a key on your account and stores it; a key
you already have can still be pasted there. `chatgpt-codex` (ChatGPT
(Codex)) reaches a ChatGPT plan's Codex quota the way the Codex CLI does:
`metacodes login --provider chatgpt-codex` signs in with the Codex CLI's
client, takes no key and no variable, and is unofficial — it may stop
working at any time.

**Paste a key.**

```sh
metacodes login --provider gemini
```

It opens the page the key is created on (for a vendor with one page per
region, the region of its default channel; `--key-page <id>` picks another),
reads the key without showing it, checks it with a request the vendor does not
bill — the vendor's own model list, the key sent the way its requests send it
— and stores it. `/login gemini` in the terminal UI does the same. A key the
vendor refuses is not stored. From a script, pass the key on standard input:

```sh
printf '%s\n' "$QWEN_KEY" | metacodes login --provider qwen --api-key-stdin
```

`--no-check` stores the key without the check, for a network that cannot
reach the vendor's model list.

**Or put it in `.env`.** One `NAME=value` per line in `<state root>/.env`; see
[LOCAL_CONFIG.md](LOCAL_CONFIG.md) for the format, the names it accepts and
how a start chooses among several providers.

**Where it is stored.** A pasted key goes to `<state root>/keys/<id>.json`
(0600), one file per provider: only that provider ever reads it, so a key you
stored for one vendor is never sent to another. `config.json` never holds a
key. When both are set, a variable (your shell's, then `.env`'s) is used
before a stored key.

**Check it.** `metacodes login status` says which provider a plain start uses
and why; `metacodes doctor` lists the names `.env` sets (never their values);
`metacodes --check-providers` lists every route — provider, channel, protocol,
model, endpoint — without sending a request.

**Forget it.** `metacodes logout --provider <id>` (or `/logout <id>`) removes
the stored key.

**Coding plans.** `kimi-code`, `zai-coding-plan` and `chatgpt-codex` are
subscriptions licensed for a person working in a coding tool. A start with nobody at the keyboard
(`-p`, `serve`, a piped REPL) on one of them prints a one-line warning; it does
not refuse. Use a pay-as-you-go key for automation.

**Common errors.**

| Message | What to do |
|---|---|
| `<vendor> refused this key; nothing was stored.` | The key was mistyped, or is for another product or region (a Kimi Code key is not a Moonshot open-platform key; a Qwen Beijing key does not work on the Singapore endpoints). Paste it again. |
| `The key could not be checked (network or provider error); nothing was stored.` | The model list could not be reached. Retry, or store it unchecked with `--no-check`. |
| `Authentication required for provider '<id>'.` | No key for that provider: paste one with `login --provider <id>`, or set one of its variables. |
| `<vendor> rejected the API key. Check <VARIABLE> in <state root>/.env or your shell, then restart.` | A request was refused with the key a variable holds; fix it there. |

## A model API of your own

For anything metacodes does not ship: a relay or proxy, a company gateway, a
server on this machine (Ollama, vLLM, LM Studio), or a vendor's special
address (a coding plan's, say). You describe the endpoint once; from then on
it is a provider like any other — in `/model`, for `--provider`, in
`--check-providers`.

### Adding one

```sh
metacodes providers add my-relay --base-url https://relay.example.com/v1 --protocol openai_chat --model glm-4.6
```

- **`<id>`** — lowercase letters, digits, `-`, `_` and `.`. It is
  permanent: offers, a stored default and session records name it. To rename
  a provider, add a new one and remove the old. It cannot be the id or alias
  of a built-in vendor.
- **`--base-url`** — where the API is: `https`, or plain `http` to this machine
  only (`127.0.0.1`, `localhost`, `::1`). It may not carry a user name or
  password; the key goes elsewhere (below).
- **`--protocol`** — what the endpoint speaks:

  | `--protocol` | The API | Requests go to | Its model list |
  |---|---|---|---|
  | `openai_chat` | OpenAI Chat Completions — most relays, Ollama, vLLM | `{base}/chat/completions` | `{base}/models` |
  | `openai_responses` | OpenAI Responses | `{base}/responses` | `{base}/models` |
  | `anthropic_messages` | Anthropic Messages | `{root}/v1/messages` | `{root}/v1/models?limit=1000` |
  | `gemini_generate_content` | Google Gemini API | `{root}/v1beta/models/{model}:streamGenerateContent` | `{root}/v1beta/models?pageSize=1000` |
  | `bedrock_converse` | Amazon Bedrock Converse | `{base}/model/{model}/converse-stream` | none |

  For `anthropic_messages` and `gemini_generate_content` the address works
  with or without its trailing `/v1` or `/v1beta`: relay documentation
  publishes both, and the root (`{root}`) is stored without it.

  A relay that serves several protocols is **one provider with one channel
  per protocol**: repeat `--protocol`. `--protocol <wire>=<url>` gives that
  channel an address of its own.
- **`--model`** — a model id, as the endpoint names it; repeat it for more.
  `--probe` asks the endpoint for its list instead
  ([below](#asking-which-models-it-serves)).
- `--display-name` — what `/model` calls it (the id otherwise).
- `--dialect <vendor>` — whose models these are, when their names do not say
  it: `openai`, `claude`, `gemini`, `glm`, `kimi`, `deepseek`, `qwen`,
  `minimax`, `mistral`, `openrouter`. Without it, metacodes infers each from
  the model name, as it does for every route.
- `--subscription-plan` — the endpoint is a coding plan licensed for
  interactive use: a start with nobody at the keyboard (`-p`, `serve`, CI)
  then prints a warning, as it does for `kimi-code`.

`metacodes providers add` with no arguments, at a terminal, asks for each part
in turn: id, display name, address, protocols, key, models (asking the
endpoint, or typed), dialect. Without a terminal every part must be given as
an argument; a missing one is an error, never a wait for input.

Before anything is written, the whole `config.json` is checked the way
`metacodes --check-providers` checks it, in the same lock that writes it; a
definition that would not load is refused and the file is left as it was.
Besides the revision counter metacodes keeps in the file, the command changes
only `custom_providers.<id>`: every other key and every other provider keep
their content and order (the file is rewritten with two-space indentation, as
every metacodes write does).

**The change applies from the next start.** A running session read its
providers when it started; start metacodes again to see the new one in
`/model`, which lists a provider once it has a key ([below](#its-key)).

What `add` writes is what you would write by hand (the full schema, with
prices, limits, controls and endpoint policies, is in
[PROVIDER_OFFER_ARCHITECTURE.md](PROVIDER_OFFER_ARCHITECTURE.md#user-defined-providers)):

```json
"custom_providers": {
  "my-relay": {
    "display_name": "My relay",
    "channels": [
      {"id": "openai", "base_url": "https://relay.example.com/v1", "protocol": "openai_chat"},
      {"id": "anthropic", "base_url": "https://relay.example.com", "protocol": "anthropic_messages"}
    ],
    "models": [
      {"request_model_id": "glm-4.6", "limits": {"context_window": 200000, "max_output_tokens": 128000}}
    ]
  }
}
```

### Its key

Three ways, depending on the endpoint:

1. **Paste it and store it** (the usual way):

   ```sh
   metacodes login --provider my-relay
   ```

   or `/login my-relay` in the terminal UI. There is no page to open — the key
   comes from whoever runs the endpoint — so it goes straight to the paste.
   The key is checked against the endpoint's model list (above), sent as the
   provider's requests send it, and stored in `<state root>/keys/my-relay.json`
   (0600). An endpoint that lists no models (or a `bedrock_converse` one)
   cannot check a key: pass `--no-check`.
2. **Read it from a variable**: `--key-env MY_RELAY_API_KEY` when you add the
   provider, then set `MY_RELAY_API_KEY` in your shell or in
   `<state root>/.env`. The name must be the provider's own: one that another
   provider reads (`OPENAI_API_KEY`, say) is refused, because a key there
   would then go to both.
3. **None**, for a server on this machine that wants no key (Ollama, vLLM
   without `--api-key`). metacodes sends a key with every request, and a
   provider with none does not start, so the placeholder `none` is stored in
   its place; such a server ignores it. Choose "none" when `add` asks for each
   part, or press Enter when `add --probe` asks for the key. Afterwards,
   `metacodes login --provider <id>` and paste `none`.

`--auth` says how the key is sent: `bearer` (the default: `Authorization:
Bearer <key>`; a provider that speaks only `gemini_generate_content` defaults
to Gemini's `x-goog-api-key` instead), `header:<name>` (the key alone in that
header, such as `header:x-api-key` for Anthropic's own API), or
`header:<name>:<prefix>` (the prefix, then the key).

### Asking which models it serves

```sh
metacodes providers probe my-relay
metacodes providers probe --base-url http://127.0.0.1:11434/v1 --protocol openai_chat
```

`probe` asks the endpoint's model list (the addresses are in the table above)
and prints each model with its context and output limits when the list gives
them. It stores nothing. For a provider you defined it sends the key a session
would use (its variable, else its stored key); for an address you have not
defined yet, give the key with `--key-env <VAR>` or `--api-key-stdin`, or
none. A request that carries a key never follows a redirect.

`providers add … --probe` asks the same list while adding: at a terminal it
asks for the key (Enter if there is none), shows the list and lets you pick
(`1,3,5-7`, or Enter for all); the context and output limits the list reports
are written with each model, and a key you pasted is stored once the endpoint
has accepted it. Without a terminal, `--probe` needs `--model` and checks
those ids against the list.

A list is a convenience, not a requirement. The endpoint has to answer with
the standard `data` array (OpenAI, Anthropic, most gateways), a `models`
object keyed by model id (some gateways), or for Gemini its `models` array.
When it answers with something else, or not at all, name the models with
`--model`: they work the same.

### Changing, listing and removing

```sh
metacodes providers list
metacodes providers add my-relay --replace --display-name "House relay"
metacodes providers remove my-relay
```

- **`list`** shows each provider you defined — its channels, models, and
  where its key comes from (which variable, set where; the stored key) — and
  whether it is disabled.
- **`add <id> --replace`** changes an existing provider. Only what you give
  changes: `--display-name`, `--base-url` with `--protocol` (the channels),
  `--model` (the model list; a model you keep keeps the price, limits and
  controls written for it), `--key-env`, `--auth`, `--dialect`. Everything else
  in the definition stays as it was. Its id never changes. A new address on
  another host is refused while a key is stored for the old one: run
  `metacodes logout --provider <id>` first, so the key you stored for one
  operator is not sent to another.
- **`remove`** takes the provider whole: its definition, its settings
  (`providers.<id>`, which `/providers disable` writes), its stored key and
  stored login, and the default model when that was one of its. `/providers
  remove <id>` in the terminal UI does the same for a provider you defined;
  for a built-in vendor it removes only that vendor's settings. A running
  session keeps listing a removed provider until it restarts.

### Examples

**A relay that speaks two protocols.** One provider, two channels: the OpenAI
one at the address as given, the Anthropic one at its root.

```sh
metacodes providers add my-relay --display-name "My relay" \
  --base-url https://relay.example.com/v1 --protocol openai_chat --protocol anthropic_messages \
  --model glm-4.6 --model kimi-k2
metacodes login --provider my-relay
```

**Ollama on this machine.** It wants no key: press Enter when the probe asks
for one, and the placeholder `none` is stored in its place. Plain `http` to
`127.0.0.1` is allowed.

```sh
metacodes providers add ollama --base-url http://127.0.0.1:11434/v1 --protocol openai_chat --probe
```

**vLLM on this machine**, started with `--api-key`: the key from a variable.

```sh
metacodes providers add vllm --base-url http://127.0.0.1:8000/v1 --protocol openai_chat \
  --key-env VLLM_API_KEY --model Qwen/Qwen3-Coder-30B-A3B-Instruct
```

**Alibaba Cloud Model Studio (Bailian) Coding Plan.** The plan has its own
address and its own keys (`sk-sp-…`); the pay-as-you-go address and keys of
the built-in `qwen` provider do not draw on it. Use the model ids the plan's
console lists.

```sh
metacodes providers add bailian-coding --display-name "Bailian Coding Plan" \
  --base-url https://coding.dashscope.aliyuncs.com/apps/anthropic --protocol anthropic_messages \
  --model qwen3.7-plus --subscription-plan
metacodes login --provider bailian-coding
```

The plan's OpenAI-compatible address is `https://coding.dashscope.aliyuncs.com/v1`
(`--protocol openai_chat`). If the plan's endpoint lists no models, the key
check cannot run: store the key with `--no-check`.

**Volcano Engine Ark (火山方舟) Coding Plan.** Its address is
`https://ark.cn-beijing.volces.com/api/coding` for the Anthropic protocol and
`https://ark.cn-beijing.volces.com/api/coding/v3` for OpenAI Chat
Completions. The general address `…/api/v3` does not draw on the plan and is
billed separately.

```sh
metacodes providers add ark-coding --display-name "Ark Coding Plan" \
  --base-url https://ark.cn-beijing.volces.com/api/coding --protocol anthropic_messages \
  --model ark-code-latest --subscription-plan
metacodes login --provider ark-coding
```

**Coding plans are for a person in a coding tool.** Both vendors' terms limit
the plan keys to interactive use in coding tools; Alibaba's forbid automated
scripts, application backends and non-interactive batch calls, and warn that
misuse may suspend the subscription or ban the key. Do not run `-p`, `serve`
or CI on them; `--subscription-plan` makes metacodes say so when a start
does.

### Common errors

| Message | What to do |
|---|---|
| `… cannot be an endpoint: plain http goes only to this machine (127.0.0.1, localhost, ::1); use https.` | Use the endpoint's https address. A server on another machine of your network needs https too, or a definition written by hand with `"endpoint_policy": {"require_tls": false}`. |
| `… cannot be an endpoint: it carries a user name or password …` | Take `user:password@` out of the address; store the key with `login --provider <id>` or `--key-env`. |
| `'<id>' is <vendor>, a provider metacodes ships …` | Choose another id. |
| `… already defines '<id>'. Change it with … --replace …` | The id is taken: add `--replace` to change that provider, or choose another id. |
| `--key-env <NAME>: <provider> already reads it …` | Another provider reads that variable; use a name of this provider's own. |
| `… answered 401: it refused the key; nothing was written.` | The key, or the way it is sent (`--auth`), is wrong for that endpoint. |
| `… answered, but with neither a "data" array nor a "models" object` | The endpoint's model list is in a shape `probe` does not read. Name the models with `--model`. |
| `… could not be reached (RequestFailed)` | The address is wrong, the server is not running, or the network blocks it. |
| `a key is stored for '<id>' (…), and it would now go to <address>.` | `--replace` was given a new host. `metacodes logout --provider <id>` first, then replace. |
| `warning: part of <state root>/config.json did not apply (…)` at start, then `unknown provider '<id>'` | A definition you edited by hand does not load. `metacodes --check-providers` names the reason. |
| The provider is not in `/model` | It has no key yet: `/model` lists a provider once it has one ([Its key](#its-key); a server that needs none takes `none`). Or it was added while the session was running: start metacodes again. |

## Which one a start uses

A start takes the first of these that applies: a provider named by
`--provider` or `METACODES_PROVIDER`; a preset named by `--preset` or
`METACODES_PRESET`; the preset the working directory remembers; the default
you stored in `/model` (press Tab there for "from now on"); a Metask
sign-in; what `<state root>/.env` chooses; otherwise none, and the terminal
UI opens without a model. A provider you defined is chosen the same ways
(`metacodes --provider my-relay`, a preset that names one of its models, or
in `/model`). The full order is in
[LOCAL_CONFIG.md](LOCAL_CONFIG.md#which-provider-and-model-are-used), and
`metacodes login status` shows it for your install.
