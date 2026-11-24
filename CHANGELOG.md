# Changelog

The standalone repository is versioned per `build.zig.zon`; the first tagged
release is `0.1.0` (2026-08-29). Entries titled **"Historical —"** were
imported from the pre-extraction `cc-zig` line — their version numbers and
dates are historical labels, not release promises of this repository. Current
status, compatibility boundaries, and entry points are defined by
[README](README.md), [ROADMAP](ROADMAP.md), [doc/API.md](doc/API.md), and
[OPEN_SOURCE_READINESS.md](OPEN_SOURCE_READINESS.md).

## Unreleased

### Added

- **Dragging over text in the TUI can copy it** (preview `copy_on_select`).
  With `--preview=copy_on_select` or `{"preview": {"copy_on_select": true}}`
  the interactive TUI reports the mouse; releasing a left-button drag copies
  the text under it through OSC 52 (and `pbcopy` in a local macOS session)
  and the prompt shows `Copied to clipboard`, like Claude Code's fullscreen
  mode. While it is on, the wheel no longer scrolls the scrollback and the
  terminal's own selection needs its modifier key. macOS and Linux only.
- **File references in replies open with Cmd/Ctrl+click.** The TUI renders a
  Markdown link (`[notes.txt](/abs/notes.txt)`, `[x](src/a.zig:42)`,
  `[docs](https://…)`) as an underlined OSC 8 hyperlink showing only its
  label, and an inline code span that reads as a file reference
  (`src/repl/render.zig:42`, `/etc/hosts`) keeps its look but becomes
  clickable. Relative paths resolve against the working directory and the
  `:line[:col]` suffix is dropped from the `file://` URL. Terminals without
  OSC 8 show the same text.

- **WorkBuddy suites run with the profile's run gates.** A bench profile's
  Lean-modelled run gates now reach the WorkBuddy suites too: the workbench
  passes them as harness parameters and the overlay turns each into its
  metacodes flag. Preview features still run on Harbor suites only, and the
  profile page names what a WorkBuddy dataset left out. Reinstall the overlay
  (`python3 -m scripts.eval.workbuddy.install_overlay <checkout>`) on every
  WorkBuddy checkout; the bench node protocol is now 9, so rerun
  `metacodes bench setup --executor <name>`.

- **Models can be priced in config.json, and bench runs use OpenRouter
  prices.** `model_prices` in `~/.metacodes/config.json` prices a model in
  USD per million tokens; every cost meter (the session cost, evaluation
  budgets, the isolated verifier, the Teamwork ledger) charges it before the
  built-in table, whose Sonnet fallback overstates most open models 20–100×.
  A bench run looks its model up in OpenRouter's catalog (cached for a day),
  records the price on the run and writes it into the trial's config, so
  Teamwork budgets and verifier caps mean real dollars. `"model_prices":
  "off"` in workbench.json skips the lookup; the bench node protocol is now 7.

- **A directory can be left without a default** (part of #489). With
  `"global_default": false` at the top level of `config.json`, the `/model`
  default, a Metask sign-in and `.env`'s choice (levels 4 to 6 of the startup
  order) decide for no directory: a start uses what it names (`--provider`,
  `--offer`, `--preset`, `--api-key`, `METACODES_PROVIDER` or
  `METACODES_PRESET` in the shell) or the preset its directory remembers. In a
  directory that remembers none, the TUI opens without a model, and a message
  gets a red note naming `/model`, the presets and the `directory_presets`
  entry to add; `-p`, `serve` and `--web` stop with exit code 2 before any
  request. So an unfamiliar repository uses no account until one is chosen for
  it. Keys and sign-ins still serve the route that is chosen; `/logout` leaves
  the session without a model instead of switching to `.env`'s choice, and
  `metacodes login status` marks the levels left out. A value that is not a
  boolean fails to load with `InvalidGlobalDefault`; a malformed preset does
  not hide the setting ([LOCAL_CONFIG.md](doc/LOCAL_CONFIG.md#presets)).

- **Teamwork trials no longer stop at permission prompts.** `teamwork run`
  has no `--permission`, so its verifier asked for each command and, with
  nobody to answer, the audit ended unavailable and nothing merged. A
  teamwork trial now writes user-level allow rules for the built-in tools in
  its disposable container, as a headless trial runs with
  `bypassPermissions`.

- **Teamwork trials get a cap that lasts.** The dollar cap now follows the
  difficulty at easy $20, medium $40, hard $80 (otherwise $40), since the
  ledger charges models without their own price at the Sonnet fallback
  rates; a run that spends its budget is scored instead of counted invalid,
  and the run directory (ledger, seat logs, no worktrees) is kept with the
  trial as `teamwork-run/`.

- **A bench profile can measure teamwork.** The `teamwork` preview feature
  runs each Harbor task through `metacodes teamwork run`: task containers get
  the permissions bubblewrap needs, a directory without a commit gets a
  snapshot commit, the dollar cap follows the task's difficulty and the
  agent timeout triples. A run in which no implementer seat finished counts
  as invalid. It runs alone and only on an SSH executor whose entry sets
  `teamwork_privileged: true`: the container permissions are close to a
  privileged container, so only for a disposable node without credentials.
  The bench node protocol is now 4 (rerun `metacodes bench setup --executor
  <name>`).

- **A bench profile runs several models at once.** The 评测 page selects
  several models (`models` in `POST /api/profiles/run`), queuing every
  dataset once per model, and the profile page compares the models' latest
  results side by side.

- **The bench workbench shows public leaderboards next to our runs.** A
  榜单 page lists, per suite, results other harnesses and models published
  (FrontierHarness Eval v1.1 per model, Terminal-Bench 2.0/2.1, EvalPlus,
  Vals.ai and MathArena AIME, LiveMathBench, WorkBuddy-Bench, GAIA2,
  ALFWorld) with their sources, and ranks this workbench's finished jobs among
  them. Boards with costs add a pass-rate/cost scatter with the cost-pass
  frontier; hovering a point or row shows what it beats.
- **The bench workbench reports FrontierHarness-style statistics.** Every
  summary adds the pass rate's 95% interval, tasks solved at least once, cost
  per task (per-task mean, then mean over tasks) and per pass, the share of
  cost spent on runs that did not pass, cache hit rate and turns per pass. The
  compare page lists them per job and marks the jobs on the cost-pass
  frontier.
- **Bench task containers can use package mirrors and a shared apt cache.**
  `container_mirrors` on an SSH executor (`apt`, `pypi`, `conda`, `go`,
  `rustup`, `npm`) reaches every run's task containers through a Harbor
  compose overlay. With `apt`, `bench setup` runs apt-cacher-ng on the
  executor's Docker gateway (port 3142) with that mirror as its Debian and
  Ubuntu backend, so packages that trials and verifiers install are
  downloaded once per executor.

- **Bench batches can be renamed and copied.** A batch page has 重命名
  (`POST /api/batch/rename`) and 复制为新批次, which fills the 新建 page with
  the batch's version, datasets, tasks and settings. The overview's batch list
  copies, stops and deletes a batch in place, stopping asks for confirmation,
  and the 新建 form keeps what was typed across a refresh.

- **`metacodes bench pull` prepares a suite's task environments.** It pulls
  the `docker_image` of each selected task and builds the environment of
  every task without one, the same way Harbor builds it, on the chosen
  executor, with retries (`--dry-run` only lists what is not ready). Harbor's
  own build then comes from the build cache, so a flaky registry or package
  index no longer turns batch trials into invalid environment failures.

- **A bench batch can switch on advanced features.** The 新建 page of the
  bench workbench has a 高级功能 section: the Lean-modelled run gates
  (`--verification-final-gate`, `--requirement-ledger`, `--test-integrity`,
  `--delivery-cadence`, `--stall-gate`) and the preview features
  `execute_code`, `comment_guard` and `harnessmm`, all off by default. Every
  trial of the batch runs with the ticked flags, and the batch page lists them.
  `POST /api/batches` and `POST /api/runs` take them as `features`.
  The bench node protocol is now 2: rerun `metacodes bench setup --executor
  <name>` for each SSH executor.

- **An interactive start offers a newer release.** Like Codex, `metacodes`
  started as the TUI from a release install checks for a newer release in the
  background at most once a day, and on a later start offers it: update now
  (runs `metacodes update`, then exits so the new version starts next), skip,
  or skip until the next version. `-p`, `serve`, `--web`, teammates and
  development installs never check; `METACODES_NO_UPDATE_CHECK=1` or
  `METACODES_NO_PROBE=1` turns it off. The state is
  `<state root>/update-check.json`.

- **`metacodes mcp add`, `mcp add-json` and `mcp remove`.** Install an MCP
  server from the command line: `mcp add <name> <url>` (or `-- <command>
  [<arg>...]` for a stdio server) writes it into `mcpServers` of
  `<state root>/config.json`, changing only that member, atomically and with
  mode 0600. Claude Code's and Codex's spellings of the command work too. An
  entry no session could use is refused; a configured name needs `--force`.
  After writing, `add` connects the server once and says what it found (for a
  401, the `mcp login` command). `remove` also forgets the server's stored
  login. `mcp list` now checks each server (`--no-check` skips it) and says
  `auth: not logged in` instead of `auth: none`.

- **Skills can be added, edited and removed while a session runs.** Before
  each request of a top-level Run the session checks its Skill roots and each
  Skill's `SKILL.md`; when one changed it reads the Skills again, so a new
  Skill can be activated, an edited one runs its new `SKILL.md` and a removed
  one is refused, with no restart. The listings in the system prompt and the
  `Skill` tool do not change, so the prompt cache holds; a system reminder
  tells the model which Skills are new, gone or changed. A session that
  started without Skills gains the `Skill` tool with the first one. Plugin
  Skills are not watched.

- **MCP servers can be added, changed and removed while a session runs.**
  Before each request of a top-level Run, the ones after a tool batch inside a
  Run included, the session checks the files its MCP configuration comes from
  and the stored logins. A server added or changed (by `metacodes mcp add`, an
  edit, another program) connects, one that needed a login connects once
  `metacodes mcp login` has stored a new one, a removed one is disconnected,
  and a server that announces `notifications/tools/list_changed` has its tools
  read again: no restart, no `/mcp reconnect`. The system prompt and the tool
  schemas already sent stay as they were, so the prompt cache holds; the model
  learns from a system reminder that lists the new and the gone tools and what
  happened to each server, told again after compaction and never twice. A
  server defined inside the working directories (the current directory,
  `--add-dir` directories, the sandbox's `allowWrite`) is not connected
  automatically, since a command the session ran could have written it:
  `/mcp reconnect [<name>]` connects it, and restarts a named server. A
  reconnect rebuilds nothing, runs while background agents or teammates run,
  and Esc or Ctrl+C cancels it.

- **Teamwork launches its own Manager.** Configure `seats.manager` as a
  `claude_code` seat with a top-level `manager_budget_usd` and `teamwork run`,
  `resume` and `/teamwork` start that Manager CLI themselves. It runs in the
  sandbox with only its seat directory writable and only the teamwork MCP
  tools allowed; the controller that reviews, audits and merges stays in the
  metacodes process. Its allowance is held in the run's budget before it
  starts and settled by its reported cost; a Manager stopped without a report
  is charged the whole allowance, and a crash never grants it twice. Cancel or
  an exhausted budget stops the Manager and the workers without merging, once
  the Manager's relay has read the replies already written (the cancel answer
  included) or after waiting at most 2 s, and the Manager dies with its
  controller. MCP snapshots now report
  `budget.held_usd` and `budget.manager` (`none`, `run_ledger`, or
  `outside_ledger` for a `teamwork mcp` client, whose spend the cap does not
  include).

- **Teamwork progress.** A teamwork run reports every seat status change and
  phase change with a snapshot of the run: the REPL draws a panel above the
  input box (goal, `N/M done · $spent / $cap`, one line per seat with its
  harness) and `/teamwork status` prints the same summary; the interviewer
  shows `needs_you` while the approval prompt waits. `teamwork run|resume
  --events` writes `teamwork.snapshot` and `teamwork.event` wire lines to
  stdout, and Zig hosts subscribe through `teamwork_runtime.Deps.observer`.
- **`update --check` names the sessions that would block the update.** When
  an update or repair is available, `--check` now scans the install's
  processes as a real run does, without refusing or signalling anything: it
  lists the sessions running from the install and says the update would be
  refused until they exit, and names the TinyKG service pids a real run would
  stop. `--json` carries them in the new `sessions` and `services` arrays;
  `running_sessions` and `stopped_services` still record what a real run did
  and stay empty under `--check`. The exit code stays 3 (#646).

### Changed

- **Bench profiles replace batches.** A profile (评测配置) is one frozen
  metacodes version with a fixed set of advanced features, and every run
  belongs to one; the same version with the same features is always the same
  profile. Runs are queued on a profile as often as wanted
  (`POST /api/profiles/run`, 再次运行, 重跑未通过的题), and a rerun of a task
  replaces its earlier result in the profile's view. The 评测 page ticks the
  Lean run gates by default and leaves the preview features off; WorkBuddy
  datasets of a profile run without its features. `bench run` runs on the
  profile of the configured bundle with the same default features. Existing batches are merged
  into the profiles of their version and features when the service starts;
  the evaluation database moves to schema v4 (`profiles` replaces `batches`).
  `/api/batches` and `/api/batch/*` are gone.

- **The CLI tells the model which command it is.** The environment section of
  the system prompt names the command that started the session (the launcher
  name, `metacodes-dev` for a side-by-side install), says that `metacode` and
  other similarly named programs are different products, and how MCP servers
  are added, logged in to and loaded. A session asked to install an MCP server
  had run another product's CLI, whose login metacodes cannot use. The `mcp`
  subcommand's hints, and `/mcp`'s, name the same command.

- **ToolSearch and unknown `mcp__` tools name servers that changed after the
  session started.** Besides the servers that did not connect (and the ones
  still connecting), the result reads the configuration again and names a
  server added since the session last read it, which is connected before the
  next request.

- **MCP servers configured for Metacode are found too.** `~/.metacode/config.toml`
  `[mcp_servers]` (Codex format) is read as the lowest-precedence source, after
  Codex's; `"mcpImport": {"metacode": false}` in `<state root>/config.json`
  turns it off. Its stdio servers start with every session, as Codex's do.

- **`metacodes mcp login` succeeds only when the server takes the token.** The
  new token is tried with one authenticated request before it is stored; a
  401/403 fails the login, stores nothing and prints the server's answer with
  the scope requested and granted. Registration and token errors print the
  authorization server's `error`/`error_description`.

- **A configured MCP server that did not connect is reported** to the model
  (ToolSearch misses and calls to its tools name it, its cause and the fix), on
  stderr by `-p`, and in `--json` as `mcp_unavailable`.

- **Reading a credential store from Bash always asks.** A command that runs
  `security find-generic-password`/`find-internet-password`/`dump-keychain`/
  `export`, a `security` subcommand the shell computes, or `secret-tool`
  prompts even under an allow rule for `Bash` or in `bypassPermissions`,
  however it is quoted or escaped; a deny rule still denies.

- **A `--web` or `serve` session queues at most 64 messages and commands**
  (#447). Before, its queue had no bound: a client could line up any number
  of turns, each one a provider request. A `POST /message`, `POST /command`
  or UDS `message` beyond 64 is refused and queues nothing, over HTTP with
  `429 {"error":"queue full","max_queued":64}`, over the UDS with
  `{"ok":false,"error":"queue full","max_queued":64}`. Messages and commands
  count together and the turn in progress does not count, as in
  `SessionHost` (`max_queued`). `GET /state` reports `queued` and
  `max_queued`.

### Fixed

- **Ctrl-C stops a request that is waiting for its answer or whose stream
  went quiet.** The interrupt only set a flag that was read when the next
  byte arrived, so `-p` (and any caller that did not also cancel the
  request) waited for the 120 s idle limit while the provider had not
  answered yet, and indefinitely while a started stream sent nothing more.
  The liveness monitor now closes the connection of every request whose
  abort signal is set, within a quarter of a second, for every provider
  protocol and entry point. An interrupt while the answer is awaited no
  longer prints an error line.

- **Signing in over SSH no longer waits forever for a browser that cannot come
  back** (#722). `metacodes login` and `/login` sent the browser back to
  `http://localhost:1455`, which on a machine reached over SSH is not where
  the browser is: the sign-in waited with no limit and said nothing.
  - In an SSH session (`SSH_CONNECTION` or `SSH_TTY` set) `metacodes login`
    takes Metask's device code by itself and says why, and `/login` asks which
    way with the code selected, as OpenRouter's sign-in already did;
    `--no-browser` keeps the browser sign-in.
  - A browser sign-in finished on another computer ends on a page that does
    not load: paste that page's address at the prompt, or into the `/login`
    pane, and the sign-in finishes here (Metask's, and another provider's
    OAuth such as ChatGPT's). An address from another sign-in is refused and
    the wait goes on.
  - Every sign-in that waits for a localhost callback (Metask's, ChatGPT's,
    another provider's OAuth, OpenRouter's browser way) prints the forward it
    needs over SSH, with the port it bound:
    `ssh -L <port>:127.0.0.1:<port> <you>@<this machine>`.
  - `metacodes login` stops waiting for the browser after ten minutes
    (`METACODES_LOGIN_CALLBACK_TIMEOUT_MS`, `0` for no limit), stores nothing,
    and names the device-code sign-in.

- **`metacodes mcp login` over SSH no longer waits forever for a browser that
  cannot come back** (#740). It sent the browser to
  `http://localhost:<port>/callback` on the machine it runs on and waited with
  no limit. As `metacodes login` does since #722:
  - in an SSH session it prints the forward its callback needs, with the port
    it bound: `ssh -L <port>:127.0.0.1:<port> <you>@<this machine>`;
  - the address a browser on another computer ended on can be pasted at the
    prompt, and is judged as the callback would be, so one from another login
    is refused and the wait goes on;
  - it stops waiting after `METACODES_LOGIN_CALLBACK_TIMEOUT_MS` (ten minutes
    by default, `0` for no limit), exits 1 and stores nothing.

- **Refusing on the authorization page now ends `metacodes mcp login` and
  Metask's browser sign-in** (#749). Their loopback callback answered a
  redirect that carried an `error` with an error page and kept waiting:
  `mcp login` until Ctrl+C, `metacodes login` up to its bound and `/login`
  until Esc, without saying why. As another provider's OAuth already did, a
  redirect with the sign-in's `state` and an `error` now ends the wait: the
  terminal says what the authorization server said (`The sign-in was
  refused: <error> (<description>).`), and nothing is stored.

- **On Windows a sign-in opens its whole URL in the browser** (#727). The
  browser was launched with `cmd.exe /c start`, and `cmd.exe` ended the
  command at the first `&`: the browser got `…/oauth/authorize?response_type=code`
  without `client_id`, `redirect_uri`, `state` and the rest, and the sign-in
  page could not go on. The URL now goes to `rundll32.exe
  url.dll,FileProtocolHandler` from the system directory as one argument, with
  no shell in between. This covers every place metacodes opens a browser:
  Metask's sign-in and its device-code page, ChatGPT's and other providers'
  OAuth, OpenRouter's, an MCP server's, and a provider's page for creating a
  key.

- **A busy tunnel port on an SSH executor no longer fails `egress =
  "workbench"`** (#716). Setup's 容器出网 step and each run picked the
  executor-side port of their `ssh -R` tunnel at random from 20000–59999,
  mostly inside Linux's ephemeral range, so a port an outgoing connection held
  made `ssh` exit at once (`ExitOnForwardFailure`): setup then blamed the
  executor's firewall, and the run failed as a lost SSH connection. The port
  now comes from 20000–32767, below the ephemeral ranges, and when the
  executor cannot listen on it, setup and the run try another port, up to 5.
  When none works, they say the tunnel port could not be bound on the
  executor, which may also not allow remote forwarding for the account.

- **A model whose output limit is its whole context window can be used.**
  Metask's gateway lists kimi-k3.1-pro with a 1,048,576-token window and the
  same output limit. The request asked for all of it and the whole of it was
  reserved from the window, which left no room for the input: every message
  stopped before it was sent (`context blocking limit reached ...
  effective_window=0`). A request now asks for at most half the model's window
  as output, and the input keeps the other half; models whose output limit is
  under half their window (every other model the gateway lists today) send
  what they did before. An explicit `--max-tokens` is sent as given.

- **Reasoning can be switched off and on for Metask models that name no
  level.** For DeepSeek-V4.1-Flash-1017, hy4 and kimi-k3.1-pro the gateway
  says thinking can be turned off and on but lists no levels, and the sign-in
  offered `none` alone, which sent nothing: thinking was whatever the gateway
  chose. `metacodes login` and `/login` now offer `off` and `on`, and `/model`
  offers Thinking `none` or `high`; on sends `thinking: {"type":"enabled"}`
  and off sends `{"type":"disabled"}`. `none` on a gateway model that lists
  levels and can be turned off now sends `disabled` as well. A model with a
  single choice is no longer asked for one.

- **Closing the terminal or `kill` ends an idle metacodes at once** (#758).
  SIGHUP and SIGTERM were acted on only at a turn boundary, so while the
  prompt waited for input the process lived on until the 45-second fallback
  alarm ended it, without the normal shutdown. The prompt now checks for them
  while it waits and leaves the normal way within a fraction of a second,
  with the resume hint where the terminal is still open.

- **`\` then Enter starts a new line while the model answers** (#757). At
  the prompt a `\` at the end of a line followed by Enter is a newline, the
  way Apple Terminal users start one; during a reply Enter queued the draft
  with the `\` still in it. It is a newline there as well now.

- **What you type while the model answers is still in the box when it ends**
  (#756). Text typed into the input box during a reply and not sent was
  dropped when the reply ended, and the prompt came back empty. It now stays,
  with the cursor where it was, also through the reply to a message queued
  before it.

- **A paste while the model answers stays whole in the input box** (#755).
  During a reply each line break of a pasted text acted as Enter: the first
  line was queued on its own and sent as soon as the reply ended, and the
  rest stayed in the box. The paste now goes into the box whole, line breaks
  included, as at the prompt; a paste of more than three lines or 1,600 bytes
  is held as `[Pasted text #N +M lines]` there too, and the model gets the
  whole text when it is sent.

- **A language server that never publishes diagnostics no longer slows every
  Edit and Write** (#669). Each Edit and Write waited for diagnostics up to
  8 s before the write and 6 s after it, so a server that answered
  `initialize` but stayed silent (still indexing, publishing only on save, or
  stuck) added about 15 s to every call. Now, when a wait for a file runs out,
  metacodes stops waiting for that file, and for the whole server if it has
  never published anything, until the server publishes diagnostics for the
  file. A silent server costs one wait of up to 8 s; servers that publish keep
  getting their diagnostics attached.

- **Cancelling a bench build on macOS reports the cancel.** Stopping a
  process group whose leader had just exited raised `PermissionError` on
  macOS, so a cancelled `metacodes bench` build (and the worker's and
  WorkBuddy image build's stops) failed with that error instead of
  「构建已取消」. An already exited group is now treated as stopped.

- **A gateway that never answers no longer holds the start or the prompt**
  (#666, #668). A start with no stored `/v1/models` list (the first for an
  endpoint and key, or the first after a day) waited for the gateway with no
  limit, and so did a Metask sign-in session's catalog; a gateway that
  accepted the connection and stalled kept the prompt from ever appearing. The
  start now waits at most 5 s, then opens on the local model table and takes
  the list when it comes. Typing `/model` or `/models` on the Metask key route
  fetched the account's key list on the input thread, so keys, Esc and Ctrl+C
  did nothing until it answered; picking a key re-fetched `/v1/models` the same
  way. Both now load in the background: the menu says `(loading)` and fills in
  when the answer comes, and the prompt stays live. Every one of these GETs
  ends at a deadline (connect, head and body together).

- **Ctrl+D with the `/model` picker open leaves the draft alone** (#649). Over
  a draft whose cursor was not at its end, Ctrl+D went past the picker and
  deleted the character under the cursor, at the prompt and in the box under a
  reply. Now it does nothing while the draft has text; on an empty prompt it
  still counts toward the double-press exit, so the picker never traps the
  session.

- **A background job that finishes while the model is answering wakes the
  agent** (#719). When a job the model had started finished during the
  model's last answer, the turn ended without waiting, because the job was no
  longer running, and the exit only came with the next message: the agent
  stopped although its job was done. The end of a turn now also counts a
  finished job whose exit has not been announced, so the exit is delivered
  and the agent goes on, as when the job finishes during the wait.

- **The agent carries on when a background job it waits for finishes**
  (#714). After the model said it would wait for a background job, the job
  could finish and the agent stay idle until the next message, which then
  brought the job's exit along. The wait looked for finished jobs, found
  none, and then, if the job ended right then, found nothing running and
  ended the turn. It now checks what is still running before it looks for
  finished jobs.

- **A foreground Bash command is collected as soon as it exits** (#670). The
  wait slept 100 ms before it first looked at the job, so every foreground
  call, even `true`, cost at least 100 ms. It now checks at once and then
  polls in steps that grow from 1 ms back to 100 ms, checking abort before
  each one.

- **A writing Bash command no longer re-hashes a stale-index workspace on
  every call** (#670). The file-change observation asked `git status` about
  the whole workspace before each command, and `--no-optional-locks` never
  writes the refreshed index back, so a copied or synced checkout re-hashed
  every file each time (about 1 s per call at 20,000 files). Files whose
  lstat has not moved since the previous observation, with the index,
  attribute sources and ignore rules unchanged, keep git's previous answer;
  only the rest are asked, and none at all when nothing moved. The listing
  before and after the command is unchanged.

- **A paste with the `/model` picker open goes to its filter** (#650). At the
  prompt the pasted text landed in the draft under the picker; during a reply
  it reached the picker key by key, so a newline in it was Enter and applied
  the model under the cursor, moving the bill to that provider. Now, at the
  prompt and during a reply, the text up to the paste's first line break is
  added to the filter as one edit, control characters dropped; the draft is
  untouched and a paste never applies a model.

- **Shift+Tab cycles the permission mode in terminals that report modified
  keys.** iTerm2 3.7.7 and later, Ghostty, kitty, Alacritty and tmux with
  `extended-keys` send Shift+Tab as the kitty protocol's `ESC [ 9 ; 2 u` or
  xterm modifyOtherKeys' `ESC [ 27 ; 2 ; 9 ~` instead of `ESC [ Z`, and the
  TUI ignored both. The key parser now reads both forms through one table, so
  modifyOtherKeys' Shift+Enter, Ctrl+Enter, Esc and Ctrl+letters work as
  their CSI u forms do (#643).

- **FindSymbol and CodeMap no longer give up early on a language server
  that is busy publishing diagnostics, and the LSP waits around Edit and Write
  end on time** (#741). The LSP client counted its waits in 150 ms steps
  instead of keeping a deadline, and every response or diagnostics push from
  the server used up a step. A `documentSymbol` request to a server
  publishing diagnostics for other files could fail long before its 10 s
  limit, which FindSymbol and CodeMap reported as a language server that
  could not be started. A wait that nothing woke ran one step past its limit,
  plus the scheduling delay of every step: the 8 s diagnostics wait before an
  Edit or Write took about 8.3 s on an idle machine. Both waits now end at
  their deadline, and still check for an interrupt every 150 ms.

- **The TTY relogin revocation cases replay the screen with line wrap**
  (#673). The `/login` dialog shows a sign-in URL wider than the terminal and
  climbs over the rows a real terminal wraps it into; the cases replayed the
  output on a screen that cuts long lines instead, so each redraw seemed to
  climb two rows too far and erased the sign-in lines above the dialog. When
  the dialog redrew twice with the URL up, that reached the HTTP 500 notice
  and the case failed. Both relogin cases now replay with wrap, and the
  refused/unanswered case checks the whole sign-in transcript in order.

- **`/logout` and the notice under the banner follow `.env`'s
  `METACODES_PRESET`** (#489). Signed in to Metask with a `.env` that names a
  preset, `/logout` moved the session to the file's `METACODES_PROVIDER` (or
  the one provider whose key it holds), or left it without a model when the
  file named only the preset, while the next start used the preset (level 6
  of the startup order). The notice under the banner named that provider, or
  nothing. Both now take the file's choice as a start does: its preset when
  `config.json` defines it, with the preset's reasoning effort and the file's
  `METACODES_MODEL` if it sets one, else its provider. The notice reads
  `.env configures the preset fast (DeepSeek · deepseek-v4-pro); the default
  is Metask. To use it: /model, or /logout`. A preset whose provider has no
  key leaves the session without a model after `/logout`, as a start on it
  does, instead of falling to the file's provider.

- **A TinyKG service that does not answer no longer holds the prompt**
  (#667). The interactive REPL probed TinyKG, built its summary and mirrored
  its tasks before drawing the input box, so a service that accepted the
  connection and never answered cost every start the transport's 35 s
  deadline. That work now runs in the background and the REPL adopts its
  outcome before the first request (the spinner reads `Starting TinyKG`; Esc
  stops the wait), so what the model sees does not depend on the timing.
  TinyKG reads give way to the session's abort signal, so leaving the REPL or
  pressing Esc during the recall before a turn no longer waits out the
  deadline.

- **The `/model` picker takes the keys with `/vim` on** (#606). Vim's keymap
  read every key before the picker did: typing went into the input box
  instead of the filter, Esc only switched the editor to NORMAL mode, and
  Enter sent the input box to the model as a prompt while the picker was
  still drawn. Now an open picker owns the keyboard as it does without vim
  mode: typing filters, Esc clears the filter and then closes it, Enter
  applies the model under the cursor, and the input box is left alone. Vim's
  keymap takes over again once the picker closes.

- **A Metask key in `.env` no longer outranks the preset the same file
  names** (#748, part of #489). A `<state root>/.env` with
  `METACODES_PRESET=fast` (a DeepSeek preset, say) and `METASK_API_KEY`
  started on Metask, without a word: the file's key counted as a Metask
  sign-in (level 5 of the startup order) unless its `METACODES_PROVIDER`
  named another provider, so the file's own preset (level 6) was never
  reached. The file's preset now counts as its choice too: the key signs
  Metask in only when that preset's route is Metask, and otherwise waits
  until Metask is chosen, as beside `METACODES_PROVIDER`. A preset
  `config.json` does not define holds the key back as well, so the start
  reports the name instead of quietly using Metask. `metacodes login
  status` says why the key waits.

- **A stalled HTTP MCP server no longer holds `/exit` or the first message**
  (#671). The session DELETE a Streamable HTTP client sends at close now has
  1 s and goes through the abort registry, so a server that never answers it
  delays the exit by about that much instead of forever. Connecting (DNS, TCP,
  TLS) now races the startup timeout and the interrupt: an `https://` server
  that accepts TCP and stalls the TLS handshake fails at its startup timeout,
  and leaving while it connects returns at once.
- **The final OTLP flush at exit is bounded** (#672). The last flush, an
  export already in flight included, gets at most 1 s (or the export timeout
  when it is shorter) instead of `OTEL_EXPORTER_OTLP_TIMEOUT` (10 s by
  default); spans it cuts off are dropped and counted. Exports during the
  session keep the configured timeout.

- **Ctrl+C closes the `/model` picker and keeps the draft** (#607). With the
  picker open over a draft (Ctrl+O while typing), Ctrl+C went past it to the
  prompt: the draft was discarded, `Press Ctrl-C again to exit` appeared
  under a picker that stayed open, and a second Ctrl+C left metacodes. Now
  the first Ctrl+C at the prompt closes the picker whatever it shows, as Esc
  does on an empty filter (`kept …`), and the draft stays; the next Ctrl+C
  arms the exit as before. During a reply Ctrl+C still interrupts it. Ctrl+D
  leaves a non-empty draft alone, as described above.

- **Bench listeners stop listening when they are closed** (#659). On Linux,
  closing a socket does not wake a thread blocked in `accept`, so a closed
  egress proxy or Docker-gateway forwarder kept its port open and relayed one
  more connection after its run ended, and the Colima relay check left its
  probe port open. They are now shut down before they are closed.

- **The arrow keys, Home, End, Delete, Page Up and Page Down work with Caps
  Lock or Num Lock on** (#658). Under the kitty keyboard protocol a terminal
  counts the lock keys as modifiers, Caps Lock adding 64 and Num Lock 128:
  with Caps Lock on, Ghostty sends Up as `ESC [ 1 ; 65 A` and Delete as
  `ESC [ 3 ; 65 ~`. The key parser read a modifier only in `CSI u` and
  modifyOtherKeys sequences, so these keys did nothing: Up recalled no
  history at the prompt, and in the permission dialog Down, Down, Enter,
  meant to pick "No", approved the write as "Yes once". A modifier that holds
  only lock bits now leaves the key as it is; with Shift, Alt or Ctrl these
  keys are still ignored, as before.

- **The permission and question dialogs take Esc and Ctrl+C in every
  encoding** (#657). Both dialogs looked only at the first byte of each read.
  A terminal with the kitty keyboard protocol on (Alacritty, Windows Terminal
  and iTerm2 over ssh since metacodes 0.9.0; iTerm2 3.7.7 and later, Ghostty
  and kitty) sends Ctrl+C as `ESC [ 99 ; 5 u` and Esc as `ESC [ 27 u`, and
  the dialogs dropped both: Ctrl+C no longer refused in the permission
  dialog, and neither key cancelled the question dialog, whose footer says
  `Esc to cancel`. Keys that arrived in one read were cut to the first, so
  `abc` typed fast into "Type something" was answered as `a`. The dialogs now
  read keys through the prompt's key parser: these keys act as their one-byte
  forms do, and every key of a read counts. A bracketed paste never answers
  a dialog: the permission dialog ignores it, and the question dialog types
  it into "Type something" or the note being edited, line breaks as spaces.

- **The prompt's shortcuts work with `/vim` on** (#660). Only Ctrl+C and
  Ctrl+D reached them: in INSERT mode Shift+Tab, Ctrl+O, Ctrl+R, Ctrl+T,
  Ctrl+G, the Ctrl+X prefix, `?` help, the `/` and `@` menus and history on
  Up/Down did nothing, and NORMAL mode fed the terminal's raw bytes to vim, so
  Left (`ESC [ D`) deleted to the end of the line, Right changed it, Up
  appended, a paste ran as vim commands, and Ctrl+C and Ctrl+D did nothing.
  Now INSERT mode handles every key as the prompt does without vim, except the
  Esc that switches to NORMAL mode; an open help, menu or agent list takes
  that Esc first. NORMAL mode reads keys, not bytes: the arrows move the
  cursor as `h`, `j`, `k` and `l`, Enter submits as before, a paste goes in
  as text, and the other keys reach the prompt's shortcuts, so Ctrl+C and
  Ctrl+D arm the exit as in INSERT mode; a key that only edits the line
  (Backspace, Ctrl+U, Ctrl+W, …) still does nothing there. A command typed
  within 200 ms of the Esc that left INSERT mode runs; it used to go into the
  box. `D` deletes to the end of the cursor's line; it used to drop every line
  below it too.

### Fixed

- **A `204` or `304` answer no longer holds a request until the server
  closes the connection** (#579). Zig 0.16's HTTP client reads the body of a
  1xx, 204 or 304 answer, which has none, to the end of the connection, and
  `Request.deinit` does the same for a GET or DELETE whose connection it
  could reuse. On a connection the server keeps open (HTTP/1.1's default),
  ending an MCP Streamable HTTP session the server answers with
  `204 No Content` waited in its `DELETE`, with no deadline, until the server
  dropped the idle connection; so did an MCP stream resumption, MCP OAuth
  discovery, the API key list, catalog downloads and the OAuth token
  requests answered that way. Every answer is now received and read through
  `api/http_connection.zig`: a body-less answer reads as empty at once, and
  its connection is closed instead of drained, so it is not reused. The
  System-One advisor, TinyKG, sealed skills and OTLP export said
  `connection: close`, so nothing waited there; they no longer depend on it.

- **System-One, TinyKG, sealed skills, OTLP export and the legacy MCP SSE
  stream no longer ask the server to close the connection** (#661). Like the
  model requests before #573, they said `connection: close`, and a server
  told so closes right after its last byte; behind a transparent proxy that
  close can overtake bytes the proxy has not forwarded yet. An answer cut that
  way read as malformed from System-One and as invalid from TinyKG, and it
  failed a sealed skill's call, whose result is the last message of its
  stream: the part #573 lost. Some MCP hosts drop a request that says
  `connection: close` without answering, and the legacy SSE stream's GET said
  it. These requests now ask the server to keep the connection open
  (`http_connection.keepServerOpen`) and close it themselves once they have
  the answer; no connection is reused. `zig build test:keep-server-open`, part
  of `gate:static`, refuses a request with `keep_alive = false` that does not
  make that call before it is sent.

## 0.13.0 — 2026-11-20

### Changed

- **Each preview feature has its own switch.** `execute_code`, `teamwork` and
  `comment_guard` can be enabled one by one with `--preview=<list>` /
  `--no-preview=<list>` or a root `"preview"` object in `config.json`, such as
  `{"execute_code": true}`. `--preview`, `--no-preview` and `"preview": true`
  still switch them all. HarnessMM and RSI no longer need `--preview`:
  `--harnessmm` and `--rsi` alone select them. Zig embedders now set
  `RuntimeConfig.preview` to a `preview.Features` value (`.all`, `.none` or
  individual fields); the AgentCore ABI keeps `RuntimeConfigV1.preview` as
  all-or-nothing.

- **A Bench SSH executor is a `metacodes` node.** The workbench no longer
  copies a Python runtime to an SSH executor: `metacodes bench setup
  --executor NAME` installs the bundle's `metacodes` there
  (`<state_dir>/bin/metacodes`, and `~/.local/bin/metacodes` when free), and
  every run, copy-back and readiness probe goes through
  `metacodes bench node …` on that machine. The node reports its own version
  and the WorkBuddy suites prepared on it, so WorkBuddy Code and Security now
  run on an SSH executor with that executor's own checkout. `node peers`
  lists the nodes a machine drives and the workbenches that drove it.
  Re-run setup for each SSH executor once after upgrading; until then its
  readiness says the node is missing.

- **Preview features require opt-in.** `--preview` enables them; `--no-preview`
  overrides a saved root `"preview": true` in the installation's `config.json`.
  ExecuteCode JavaScript orchestration is a preview feature and is hidden and
  refused by default. Child agents inherit the setting. Python and Node.js
  expose a Runtime `preview` option; AgentCore ABI revision 29 consumes a
  reserved RuntimeConfig word for the boolean, with unchanged struct sizes.

- **The CLI no longer consults a built-in System-One advisor** (#474). Until
  now every host built on the CLI (the TUI, `-p`, `--web`, `serve`) fell back
  to the team's `metask-jev-4b` at `http://58.211.6.133:10420` whenever
  `config.json` and `METACODES_JEV_*` named no service, so a session whose
  TinyKG store held a matching memory sent the first 400 bytes of the request
  and up to eight 480-byte memory excerpts over plain HTTP to a public IP
  address nobody had been asked about. The advisor is now on only where a
  service is named, by the `jev` object of `<state root>/config.json` or by
  `METACODES_JEV_URL`; with neither, `metacodes doctor` reports
  `jev_advisor off url=- source=none`. `"jev": false` and
  `METACODES_JEV_URL=off` still mean off, and a service named in either place
  behaves as before. **This changes behavior for anyone who relied on the
  default** (it replaces the 0.3.0 default below): a machine that wants the
  team's service names it once, in `<state root>/config.json`

  ```json
  "jev": {"url": "http://58.211.6.133:10420", "mode": "advisory",
          "model": "metask-jev-4b", "decisions": ["scoped_recall"]}
  ```

  or in the environment with `METACODES_JEV_URL`, `METACODES_JEV_MODE=advisory`,
  `METACODES_JEV_MODEL=metask-jev-4b` and
  `METACODES_JEV_DECISIONS=scoped_recall` (these four are what the default
  carried; a `url` alone starts from `shadow` and every surface). That address
  is still plain HTTP; serving it over https on a hostname, and asking once on
  first run, are tracked in #474. A library host that sets
  `Config.jev_builtin_default` still gets the built-in service, and the CLI's
  choice is one constant that the session and `doctor` both read
  (`jev.CLI_USES_BUILTIN_DEFAULT`). `zig build test:builtin-egress`, part of
  `gate:pr`, now fails when a built-in destination that is on by default is a
  non-loopback `http://` URL, and the memory-agent runtime smoke runs its
  System-One arm in the build: an evaluation arm that uses the advisor reaches
  it through the service its own environment names.

- **Every request names metacodes as its User-Agent.** Provider, sign-in,
  key-check, catalog, MCP and service requests used to go out as std's
  `zig/0.16.0 (std.http)`; they now say `metacodes/<version>`
  (`src/api/http_connection.zig`). Vendors tell coding tools apart by this
  header, and their terms forbid a forged one. A request that names itself
  keeps its own (the OTLP exporter's `metacodes-otlp`).

- **A subscription plan run with nobody at the keyboard says so once.** The
  coding plans (Kimi Code, the Z.AI GLM Coding Plan) are licensed for a
  person in a coding tool, so a `-p`, `serve`, resumed-suspension or piped
  REPL start on one prints `warning: <plan> is a subscription plan for
  interactive use; its terms may not cover -p, serve or CI. Use a
  pay-as-you-go key for automation.` on stderr. It never refuses, and the exit
  code is unchanged; `--web` (a person in a browser) and teammates are not
  told. Profiles declare it as `ProviderProfile.subscription_plan`.

- **`metacodes login status` says which credential a plain start uses, and
  why** (#537). It names what a start with no flag would use,
  the step of the startup order that decides (flags and the shell, a
  preset named at start or remembered for the directory (#489), the
  default stored with `/model`, a Metask sign-in, `<state root>/.env`,
  nothing), and what each step holds: the session's path, gateway and
  expiry, `auth.json`'s model and level, where `METASK_API_KEY` is set, the
  names the `.env` sets and the provider it configures, and the providers'
  keys that are only in the shell and choose nothing. Never a key or a
  token. The start and `login status` take the decision from one place
  (`src/app/startup_order.zig`).
- **`/model` is one screen, models first** (follow-up to #527). The models of
  every configured provider are listed under a heading per provider that says
  where its key comes from and who bills it, the provider in use first and the
  cursor on the model in use; typing filters across them all, under the same
  headings. A model served on several routes lists them under it, in
  words, while the cursor is on it; Enter on the model takes its preferred
  route, Enter on a route takes that one. The reasoning level is a line under
  the list, changed with ←/→ from any row, and kept as the level wanted: each
  model shows and commits the nearest one it takes. The three scopes are named
  in the header. Providers without a key are not listed, and a filter does
  not find their models; when none is listed, the picker says so and points
  to `/login` and to this install's `.env`, by its path. Closing the picker
  without a choice prints `kept <model>`. On the Metask session, `/model`
  lists only the models the gateway serves on `/v1/messages`, with the
  reasoning levels it names (`capabilities.reasoning.efforts`); before, it
  listed the gateway's image and video models too, and offered no level.
- **`/model` starts a DeepSeek model at `high`, and keeps a level the
  session already runs with** (follow-up to #539). DeepSeek's
  `reasoning_effort` control declares `high`, the level its API uses when a
  request names none ("Thinking mode is enabled by default, with the default
  effort being `high`", api-docs.deepseek.com/guides/thinking_mode). With no
  level set, a DeepSeek model in `/model` shows `[high]` where it showed
  `[default]`, and a pick sends it by name: the request that carried
  `"thinking":{"type":"enabled"}` alone now also carries
  `"reasoning_effort":"high"` (on the Anthropic wire,
  `"output_config":{"effort":"high"}` and the same `thinking`). A route bound
  without the picker (`--provider`, `.env`, `/model use`) still names no
  level. When `/model` opens, the level the session runs with starts
  selected even when it is `none` or `minimal` (before, only a level that
  thinks did), so DeepSeek's default does not replace thinking turned off.
- **`/model` keeps the provider headings while you filter, so a match says
  which route it goes through and who bills it** (#600). Typing used to list
  the matches flat with the provider's name trailing each row, and OpenRouter
  lists about 300 models under their makers' names (`DeepSeek: DeepSeek V4
  Pro 0423`), so its rows and DeepSeek's own read alike. The matches now sit
  under the same headings as the unfiltered list (`OpenRouter · key from
  shell · billed to your OpenRouter account`), the providers with a model
  that holds the typed text whole first; the first row is the one it was.
  A list scrolled into a group opens with that group's heading in place of
  its first row, filtered or not, the cursor kept below it; when that row
  is the model whose routes are listed, the line names the model too.
  PgDn and PgUp move a row less than the window, so no model is left
  between two pages. A model's name takes the room the rest of its row
  leaves instead of a third of the width, measured in terminal columns
  (a full-width character takes two): at 80 columns the third cut 116 of
  OpenRouter's 324 names, 46 of them to the same text as another, a free
  model and its paid one among them.

- **An explicit Skill run takes the Host's context blocks** (#534). An
  AgentCore `RUN_INPUT_SKILL` Run with `RunOptionsV1.context_blocks` used to
  be refused with `INVALID_ARGUMENT`; the blocks now lead the Skill's
  invocation record, so the selected Skill sees them, and the date, from its
  first request (`doc/AGENTCORE_BINARY_ABI.md`).

- **A key login says when a variable is read before the key it stores.**
  Credential resolution reads a provider's key variables (the shell's, then
  `<state root>/.env`) before a key stored with `/login <provider>` or
  `metacodes login --provider <provider>`, and that order stays. The login
  used to say only that new sessions use the stored key; with such a variable
  set it now says which one wins and how to use the new key, by name only:
  `DASHSCOPE_API_KEY is set in your shell and is used before the stored key:
  unset it to use the key you just stored.` (or `… in <path>/.env is used
  before the stored key: remove it from that file …`).

- **One `.env` with keys of several providers opens the terminal UI and says
  where to choose** (#486). A `<state root>/.env` holding keys of several
  providers and no `METACODES_PROVIDER` still chooses none, but the terminal
  UI no longer leaves it at "add `METACODES_PROVIDER=<id>`, then restart": it
  opens without a model and says once under its banner `.env has keys for
  DeepSeek and OpenAI. Choose one with /model; Tab there applies it to every
  future session.`, and the red note of a message sent before then points to
  `/model (DeepSeek, OpenAI)`. A pick for every future session is the stored
  default later starts use (its key still read from the file); a default
  stored before ranks above the file, as it did. `-p`, `serve` and `--web`
  are unchanged: they stop and list the providers by id. `metacodes login
  status` says the same: choose one with `/model`, or add
  `METACODES_PROVIDER`.

- **The Metask sign-in moves to `www.metask-ai.com` and is kept as the Metask
  session** (#527). `/login` and `metacodes login` sign in at Metask's OAuth
  server as the public client `metacodes`, ask for `read model:invoke`, and
  come back on `http://localhost:<port>/auth/metask/callback`. There is no API
  key to choose any more: the model and reasoning level are picked from the
  `/v1/models` of the gateway the sign-in names (image-only models are left
  out; `none` is offered only for a model whose reasoning it can turn off),
  and turns go there with the session's own access token, billed to the
  account. The sign-in is stored as `oauth/metask.json`, its model and
  reasoning level in `auth.json`; a key or an older sign-in there is replaced.
  Until then an older sign-in there keeps refreshing at `napi.metask-ai.com`
  as `metacode-cli`, which Metask keeps up for the transition.
  A plain start signs in with the session, ahead of the provider `.env`
  configures and after any key that signs Metask in (#499's first part); a
  stored Metask default the session authenticates runs at the session's
  gateway. `/logout` and `metacodes logout` revoke the session at Metask
  first, bounded, and say when that fails. `metacodes login status` shows the
  session. The device-code sign-in now posts to `www.metask-ai.com` (the bare
  host answers every request with a redirect, so it failed with
  `RequestFailed`), asks for the same scope, names the client in every grant
  and the refresh, and sends no host name. It also asks for the model and
  reasoning level, as the browser sign-in does: `metacodes login --provider
  metask` at a terminal, and `/login metask` in `/login`'s pane. Before, it
  chose none, and a start on it ran the compiled default model, which the
  gateway does not serve. Without a terminal it stores only the session and
  says so. If the running session cannot switch to the chosen model, the new
  session and model choice are rolled back: the previous sign-in, stored
  default, and current route keep working together.

- **The line that ends a Metask sign-in says who signed in** (follow-up to
  #527). `/login`, `/login metask` and `metacodes login` ask the server for
  the account's name (`/api/oauth/userinfo`: its name, else its email) and
  end with `Signed in to Metask as <name> · <model> · reasoning <level>`; a
  control character in it is shown as `?`. Without an answer within 3 s the
  line is as before.

- **A suspended Metask account says so** (follow-up to #527). The Metask
  gateway refuses a suspended account with a 403 `account_suspended`, which
  read as a rejected sign-in, with "sign in again" as the next step, which
  cannot help. It now says the account is suspended and where to see to it.
  `key_quota_exhausted` reads as a used-up quota, like `insufficient_balance`.

- **`/login` signs in to Metask in the browser; `/logout` switches back to
  local configuration** (#485). `/login` alone now runs `metacodes login`'s
  browser sign-in, then asks for the API key, model and reasoning level in
  the pane (an account without keys is told where to create one); Esc at any
  step stores and changes nothing. Once chosen, `auth.json` is written as
  `metacodes login` writes it, the session moves onto Metask at once, and a
  stored `/model` default is forgotten so the next start uses the sign-in
  (`metacodes login` now forgets it too). The provider list it used to open
  is `/login <provider>` (the pane names those providers); `/login metask` is
  still the device-code sign-in, which the pane names for a machine without
  a browser. The new `/logout` removes both Metask sign-ins (`auth.json` and
  `oauth/metask.json`), forgets a stored default that resolves to Metask,
  drops every Metask credential the process holds, and moves a session on
  Metask to the provider `.env` configures (`Switched to <provider> (from
  .env)`: the parenthesis names where its key came from, and a Metask that
  `.env` configures runs on `.env`'s key) or leaves it without a model; it
  names a `METASK_API_KEY` still set in the shell or `.env`. `/logout
  <provider>` removes the key `/login <provider>` stored. Neither runs in
  the middle of a turn. A start on Metask while `.env` configures another
  provider says so once under the banner (`.env configures DeepSeek; the
  default is Metask. To use DeepSeek: /model, or /logout`).
- **A provider named at start without a key opens the TUI without a model,
  and a stored default without one is passed over** (#485). `--provider`,
  `--offer`, `METACODES_PROVIDER` or `.env` naming a provider that has no
  credential no longer stops the TUI, nor quietly uses another provider: the
  TUI opens unbound and its note names the variables that provider reads, or
  `/login metask` for Metask (`-p` still stops with the provider's help). A
  `/model` default (`global_selection`) whose provider has no credential is
  passed over for the Metask sign-in or `.env`, with one notice (`The
  default model, X, has no key or sign-in; this session uses Y.`), where it
  used to stop the start.
  A Metask default is served by the browser sign-in's key (`auth.json`) when
  there is no device-code sign-in: it used to stop with `Metask session is
  unavailable`.
- **`metacodes logout` removes both Metask sign-ins and says which** (#499,
  part 2). It used to remove `auth.json` only, leaving the device-code
  sign-in and its refresh token in `oauth/metask.json` usable. It now removes
  both (and a key stored with `login --provider metask`, which `logout
  --provider metask` now also does), forgets a stored default that resolves
  to Metask so the next start falls back instead of failing, and names a
  `METASK_API_KEY` still set in the shell or `.env`. README's quick start
  signs in with `metacodes login`, or `metacodes login --provider metask
  --no-browser` on a machine without a browser.
- **`metacodes` with nothing configured opens the terminal UI instead of
  exiting** (#484). With no flag, stored `/model` default, Metask sign-in or
  `.env` provider, or with a Metask sign-in whose key and model were never
  chosen (`Metask login is incomplete`), the TUI starts without a model: the
  banner's model line reads `not set — /login, or configure .env`, slash
  commands work, and a prompt — or `/retry`, `/init`, `/commit`, `/review`,
  `/btw`, `/recap`, a Skill — is not sent. A red note in its place names
  `/login`, this install's `.env` (and `.env.example` when an install wrote
  it), the provider keys the shell holds by name only (they are still never
  used on their own: `/model` picks one) and doc/LOCAL_CONFIG.md. The prompt
  stays in the history for ↑, no request of any kind goes out (not even the
  `/v1/models` probe), and no session directory is made until a model is
  chosen. `-p`, `-`, `serve`, `--web` and a REPL whose input is a pipe still
  stop at once, non-zero, with the sign-in hint. The banner now also says
  where the model's credential came from — `· Metask`, `· from .env`,
  `· from shell`, `· saved key`, `· signed in`, `· --api-key` — and
  `metacodes install` ends with the next step while the install has neither a
  Metask sign-in nor a `.env`.

- **`/model` lists only routes it can apply, and takes no key** (#488). A
  route is listed when a credential resolves for it now, by the resolution a
  commit binds with, without sending a request: the environment,
  `<state root>/.env`, a key `/login <provider>` stored, a provider's stored
  OAuth login, a credential-pool member, `--api-key` for its provider, and
  for Metask the session's own key or, in a session started on another
  provider, the key `metacodes login` stored in `auth.json` (a pick of a
  Metask route now binds that key; it used to fail with
  `MissingCredentials`). Only a missing credential takes a route off the
  list: one refused for another reason (two names of its key that
  disagree, say) stays listed, and a pick says why. A provider with no such
  credential is no longer a row that leads to a sign-in or a key field: it
  is not listed. A pick whose credential went away after the picker listed
  it shows the variable to set, this install's `.env` and
  `doc/LOCAL_CONFIG.md` (for Metask, `/login` first), and starts nothing.
  The in-picker sign-in and key-paste stage of
  #67 are gone; `/login <provider>` pastes a key or signs in, as before. A
  pick that moves the session to another provider says on a second line who
  bills it from then on (`from now on billed to your DeepSeek account`).

- **`KIMI_API_KEY` is the Kimi Code subscription's key, no longer an alias
  of `MOONSHOT_API_KEY`** (#487). The `kimi` profile (the Moonshot open
  platform) now reads `MOONSHOT_API_KEY` only, and `KIMI_API_KEY`
  authenticates the new `kimi-code` profile beside its canonical
  `KIMI_CODE_API_KEY`. Kimi's own Codex and Hermes guides give the
  subscription key that name, so with it set `--provider kimi` sent a
  subscription key to the platform, a different account. A platform user who
  set only `KIMI_API_KEY` renames it to `MOONSHOT_API_KEY`; until then
  `--provider kimi` stops with `Authentication required for provider 'kimi'`
  before any request is sent. `KIMI_CODE_API_KEY` and `KIMI_API_KEY` holding
  different values is refused as conflicting, as the GLM plan's names are.
- **A `SessionHost` submission's own `model` and `permission_mode` are
  journaled as the daemon journals a message's fields** (part of #445). The
  driver writes a `config_changed` line for each one it applies, where
  0.12.0 wrote the `command_result` of `set_model` and
  `set_permission_mode`. When either is refused, `message_rejected` says why
  in the daemon's words, for example `model not available for current
  provider` or `bypassPermissions is disabled by settings`, where 0.12.0
  named the error.
- **A `SessionHost` configuration command is journaled as the daemon's
  `/command` is** (part of #445). An accepted `set_model`,
  `set_permission_mode` or `set_reasoning_effort` now writes a
  `config_changed` line (`model` as resolved, `mode`, `reasoning`) before
  its `command_result`, as `/model`, `/mode` and `/effort` do through the
  daemon's config sink, and `set_additional_directories` writes
  `config_changed{dirs}` for each directory it adds, as `/add-dir` does.
  0.12.0 wrote the `command_result` alone. The permission mode is journaled
  by a config sink on the Session's permission context, so a submission's
  mode is journaled once, as before.
- **A request whose sign-in or key was rejected, or whose balance ran out,
  ends by saying what to do instead of suggesting `/retry`.** The TUI ended
  every failed request with `Retry with /retry, or switch models or compact
  the context first.`, and a retry cannot help either of these. On HTTP 401
  or 403 the last line is now `Your Metask sign-in is no longer valid. Sign
  in again: /login` on Metask, and on another provider `DeepSeek rejected
  the API key. Check DEEPSEEK_API_KEY in <state root>/.env or your shell,
  then restart.`, with that provider's name and key variable. On HTTP 402,
  or when the provider's error code is `insufficient_balance` or
  `insufficient_quota` (OpenAI answers a used-up quota with 429), it is
  `Your Metask balance has run out. Top up your Metask account, or switch
  provider: /model`, or `DeepSeek reports no balance or quota left. Top up
  with DeepSeek, or switch provider: /model`. `-p` prints the same line on
  stderr after the raw error, naming the command that was run
  (`metacodes login`) and `--provider` where the TUI names `/login` and
  `/model`; its exit code stays 1. Every other failure keeps the old
  advice, and nothing is retried or switched by itself.

### Added

- **OpenRouter is built in, and `/login openrouter` signs in on OpenRouter's
  own site.** OpenRouter's PKCE sign-in creates an API key on the user's own
  account: `/login openrouter` and `metacodes login --provider openrouter` ask
  which way — the browser on this machine (a loopback callback on any free
  port, taken only with its own state), or another device (`--device-code`;
  the page shows a code to paste back, the way over SSH, offered first there)
  — trade the code and the verifier as JSON, and store the key in
  `<state root>/keys/openrouter.json` like a pasted one, with what
  `GET /api/v1/key` said about it then (label, spending limit, expiry, free
  tier). The third way is a key the user already has (`/login openrouter`'s
  last choice, or `--api-key-stdin`): checked against `GET /api/v1/key`,
  which answers 401 without a valid key and is not billed, and described the
  same way. Nothing here can delete the key on OpenRouter (that takes a
  management key): `/logout openrouter` removes it from this machine and
  names the page where its owner deletes it
  (`https://openrouter.ai/keys/<sha256 of the key>`), and a new sign-in names
  the key the previous one left. `login status` shows where the key came from
  when OpenRouter is the provider a start uses. `OPENROUTER_API_KEY` is read
  without a configured catalog. A 401 from OpenRouter says to sign in again; a
  403 (a spent key limit, a guardrail) keeps OpenRouter's own words.
  `METACODES_OPENROUTER_URL` (https, or plain http to a loopback host) moves
  every OpenRouter address, requests included, for development and tests.

- **`/model` lists the OpenRouter models the account can use.** After a
  sign-in or a pasted key, and on `/providers refresh`, the account's own
  listing (`GET /api/v1/models/user`, which applies its provider
  preferences, privacy settings and guardrails) gives one route per model
  that takes tools over chat completions, all on OpenRouter's router channel:
  OpenRouter picks the upstream (its default routing — price, speed, uptime,
  fallbacks), and the price shown is the model's listed one. The listing is
  kept trimmed in `<state root>/cache/models/` (no key in it); a start reads
  it whatever its age, so a stored `/model` default on an OpenRouter model
  resolves without a request, and the REPL fetches it again in the
  background when none is kept or it is a day old and a key is set (as with
  a key in `.env`). An OpenRouter that is not set up says `/login openrouter`
  in `/model`'s setup, as Metask's says `/login`.

- **OpenRouter requests say who is calling.** Every request on a route in
  OpenRouter's dialect carries OpenRouter's app attribution
  (https://openrouter.ai/docs/app-attribution): `HTTP-Referer:
  https://github.com/metask-ai/metacodes`, `X-OpenRouter-Title: metacodes`,
  `X-OpenRouter-Categories: cli-agent`, and no visibility header, so the app
  is listed in OpenRouter's rankings. Nothing in them is about the user, and
  no other provider's requests carry them.

- **A configuration entry that names a built-in provider is passed over
  alone.** `custom_providers.<built-in id>` used to fail the whole
  `custom_providers` section; it is now skipped by itself, said once, and the
  user's other providers load. `provider_catalogs.openrouter` is passed over
  the same way now that OpenRouter is built in.

- **`/login <provider>` and `metacodes login --provider <provider>` reach every
  built-in vendor.** OpenAI, Google Gemini, Alibaba Qwen, MiniMax and the
  Moonshot Kimi open platform declare their key pages now, as DeepSeek, the
  GLM Coding Plan, Kimi Code and Bedrock did: the login opens the page
  (Qwen, MiniMax and Kimi have one per region, the default following the
  region of the default channel), reads the pasted key, checks it against the
  vendor's unbilled `/models` and stores it in `<state root>/keys/<id>.json`.
  The check now carries the key where the vendor's requests do: Gemini's
  `x-goog-api-key`, where a bearer token is answered 401 whatever the key, and
  Gemini's 400 `API_KEY_INVALID` counts as a refused key rather than a failed
  check. `metacodes login --provider openai` takes a pasted key too while no
  OAuth client is configured for OpenAI; it used to start the browser sign-in
  and stop on the missing client id.
- **`chatgpt-codex`: a ChatGPT plan's Codex quota, the way the Codex CLI
  reaches it. Unofficial.** `/login chatgpt-codex` and `metacodes login
  --provider chatgpt-codex` sign in at `auth.openai.com` in the browser with
  the Codex CLI's public client (`app_EMoamEEZ73f0CkXaXp7hrann`), and say
  first that the sign-in is unofficial and may stop working at any time
  (`ProviderProfile.oauth_support`). The redirect can only land on the two
  ports that client registered, 1455 then 1457, which Metask's own sign-in
  also uses: with both taken the sign-in stops and names them, and nothing is
  sent to whatever holds them. A refusal from the authorization server now
  ends the wait and says what it said (`missing_codex_entitlement` is a
  workspace without Codex), where it used to wait on. The sign-in is stored
  as `oauth/chatgpt-codex.json` with the ChatGPT workspace the ID token names
  (`account_id`; the ID token itself, which names the user, is not kept).
  Turns go to `chatgpt.com/backend-api/codex/responses` with the route's
  request profile (`provider/request_profile.zig`): `originator: metacodes`,
  `chatgpt-account-id` read from the token the request carries, `accept:
  text/event-stream`, `include: ["reasoning.encrypted_content"]` and
  `instructions` always; the `openai` provider's requests are unchanged. A
  used-up plan (`usage_limit_reached`) and a plan without Codex
  (`usage_not_included`) are no longer retried: the failure says when the
  plan resets, in local time and as a wait, or that it never will. Signing
  out (`/logout chatgpt-codex`, `metacodes logout --provider chatgpt-codex`)
  revokes the refresh token at `auth.openai.com/oauth/revoke` first, bounded,
  then deletes the sign-in. It is a subscription plan: a `-p` or `serve`
  start on it says so once. The ten models are a static list, GPT-6.2
  Sol first (a start that names no model uses it); the
  device-code sign-in, the `x-codex-*` usage headers and zstd request bodies
  are not done.

- **`metacodes providers add|probe|list|remove`: a model API of your own
  without writing JSON** (`doc/PROVIDERS.md`). `providers add <id> --base-url
  <url> --protocol <wire> --model <id>` writes `custom_providers.<id>` in
  `<state root>/config.json` — a relay, a company gateway, Ollama or vLLM on
  this machine, a vendor's coding-plan address — after checking the whole file
  the way `--check-providers` does, inside the lock that writes it; a
  definition that would not load, an address the endpoint policy refuses
  (plain http to another machine, a user name or password in the URL), a
  built-in id and a key variable another provider reads are refused before
  anything is written, and every other key of the file keeps its content and
  order. A relay that serves several protocols is one provider with one
  channel per `--protocol`. `--probe` asks the endpoint's model list (OpenAI
  `/models`, Anthropic `/v1/models` with `anthropic-version`, Gemini
  `/v1beta/models`; the standard `data` array or an enriched `models` map), at
  a terminal lets you pick, and writes the limits it reports; `providers
  probe` lists without storing. With no arguments at a terminal, `add` asks
  for each part. A server on this machine that needs no key (Ollama, vLLM)
  gets the placeholder `none` stored as its key when you answer "none" (or
  press Enter at `--probe`'s key prompt): a provider with no key does not
  start, and such a server ignores it. `--replace` changes an existing one
  and keeps what was written by hand. `providers remove` takes the
  definition, its settings, its stored key and login, and a default on one of
  its models. Each change applies from the next start, and the commands say
  so.

- **A provider of your own takes a pasted key.** `/login <id>` and `metacodes
  login --provider <id>` now work for a provider defined in
  `custom_providers`: there is no page to open, so they go straight to the
  paste, check the key against the provider's model list the way its requests
  send it, and store it in `<state root>/keys/<id>.json`, which only that
  provider reads. The check may be plain http to a server on this machine,
  as the provider's own requests may.

- **A coding plan of your own can say it is one.** `providers add
  --subscription-plan` (or `"subscription_plan": true` in `custom_providers`)
  marks a provider you define as a subscription plan, as `kimi-code` and
  `zai-coding-plan` are: a `-p`, `serve`, resumed-suspension or piped start on
  it prints the one-line warning that its terms may not cover them. The coding
  plans of Alibaba Cloud Model Studio and Volcano Engine Ark, which
  `doc/PROVIDERS.md` shows defined this way, limit their keys to interactive
  use in coding tools.

- **A Linux sandbox backend: bubblewrap.** With `sandbox.enabled`, Bash,
  Monitor, skill `!` lines, the teamwork reviewer's check command and the
  Claude Code seat's CLI now run on Linux in bwrap mount, pid and IPC
  namespaces translated from the same settings Seatbelt reads on macOS:
  `/` read-only, the write roots bound writable at their physical paths,
  `denyWrite` read-only and `denyRead` hidden on top, `--new-session
  --die-with-parent`. bwrap is `/usr/bin/bwrap`, `/bin/bwrap` or the absolute
  path in `METACODES_BWRAP`, never `PATH`, and is probed once per process; one
  that cannot create a user namespace counts as no sandbox, so
  `failIfUnavailable` refuses and `autoAllowBashIfSandboxed` does not apply.
  A domain list in `network` cuts the network off under bwrap (no per-host
  filter). Teamwork seats on Linux get the sandbox too, so an implementer seat
  can build and test in its workspace instead of running read-only commands
  only.

- **Named presets, and a preset a directory remembers** (part of #489).
  `config.json` keeps named setups under `presets`, each in the shape
  `global_selection` has (an `auto_route` selector or a `pinned_offer`, with
  `controls` such as `reasoning_effort`), and `directory_presets` maps a
  directory (its git worktree root, else the directory itself) to a preset by
  name, so editing a preset changes every directory that uses it. A start
  takes `--preset <name>` or `METACODES_PRESET` (from the shell, or from
  `<state root>/.env`) and applies the preset as the flags naming the same
  route would; `--model`, `--channel` and `--reasoning-effort` replace one
  field for that run without editing it, and `--provider`/`--offer` set it
  aside. The startup order gains two levels and has seven: flags, a preset
  named at start, the directory's preset, the `/model` default, a Metask
  sign-in, `.env` (its `METACODES_PRESET` before its `METACODES_PROVIDER`),
  nothing; `metacodes login status` shows them. A preset `config.json` does
  not define stops `-p`, `serve` and `--web` with exit code 2, listing the
  presets; the TUI says so under its banner and starts without it. Nothing is
  written into a project. Malformed entries fail to load with
  `InvalidPreset`, `InvalidPresetName` or `InvalidDirectoryPreset`; saving a
  preset or a directory's choice from `/model` comes with the TUI part of
  #489, until then they are written by hand ([LOCAL_CONFIG.md](doc/LOCAL_CONFIG.md#presets)).

- **A `SessionHost` Session can move onto another provider route, journaled
  as `config_changed{route}`** (issue #16, part of #445). The CLI's `/model`
  commit moves the session's provider, endpoint, credential and model
  together and broadcasts the route's identity; `SessionHost` had no route
  at all. The new `Command.set_route` takes a `Route` the Host's provider
  control plane bound (`binding`: provider kind, wire protocol, auth scheme,
  dialect, endpoint, credential, model; and the provider, channel, protocol,
  offer id, credential reference and scope that identify it). The driver
  applies it between Runs through the new `AgentSession.setRoute`, which
  swaps all of them at once and keeps the conversation and reasoning effort
  (an effort the new provider cannot take is refused with
  `AgentEffortUnsupportedProvider`). It then journals
  `config_changed{model}` and `config_changed{route}`, as the CLI does, and
  never the credential. A refused route changes nothing and journals no
  `config_changed`. A teammate a lead opens afterwards runs on the lead's
  route (`TeammateSpawn.lead_route`, applied by `InheritLead`). An
  `AgentSession` now keeps its own copy of `SessionConfig.auth_scheme`.
- **A hosted lead's members follow the permission rules and directories it
  gains, as the daemon's teammates do** (part of #445). Under
  `session_host.InheritLead` a member decided its tool calls with what its
  configuration held when it opened, so a rule the lead gained later
  (`update_permission_rules`, an "allow always" or "deny" answer) or a
  directory it added (`set_additional_directories`) never reached it. The
  new `TeammateFactory.permissions = .lead`, which `InheritLead` declares,
  opens each member through the new `AgentSession.inheritPermissions`: it
  decides every tool call with its lead's imported rules, additional
  directories and Session memory as they are at that call, from its next
  tool call on, and refuses its own `update_permission_rules` and
  `set_additional_directories` (`PermissionsInherited`). Each decision holds
  the lead's lock (`permission/lent.zig`); the lead frees replaced rules
  only after it, and its AgentSession outlives its members'.
- **A `SessionHost`'s model catalog can be refreshed while it runs, as the
  daemon's is** (part of #445). The daemon's catalog is its cached
  `/v1/models` answer, replaced when the background refresh lands;
  `Options.models.catalog` was fixed for the Host's life, so a model the
  refresh adds stayed refused. The new `SessionHost.setModelCatalog`
  replaces it (copied): every Session's next `Submission.model` or
  `set_model` resolves against the new catalog, and the model a Session is
  on stays in force. A Host without `Options.models` gets
  `error.ModelPolicyUnset`.
- **An embedded Session's Runs can be gated by the project's rules, as the
  daemon's are** (part of #445). `SessionConfig.run_control` opens, for every
  Run on a durable `run_journal`, the `RunControl` the bundled daemon opens:
  with `project_rules = .enforced`, an active bundle in
  `<dirname(run journal root)>/project-rules` for the workspace root is
  re-attested before the provider request, decides each tool call through
  the project kernel, and publishes the Run's operational observer after it;
  a missing or invalid kernel configuration, a bundle that fails
  attestation, or a running background job or active team fails the Run
  before any provider request. Such a refusal fails only that Run, as the
  daemon reports it failed and takes the next message: the submission's
  text stays out of the Conversation and the Session is idle again, not
  poisoned (a journal that cannot open still poisons). A refused resumption
  of a suspended Run (`AdmittedRun.resumeWithResults`) leaves the answer
  out of the Conversation too, and `SessionHost` keeps the suspension:
  `run_done` names the error, the request is announced again under its id,
  recorded open, and a later answer resumes the turn. `abandoned_run = .record_abandoned` closes a
  Run whose process died as abandoned and runs the next one, as the daemon
  does; the default stays `fail_closed`. Either setting on an ephemeral
  Session is refused (`RunControlRequiresRunJournal`), and a Session that
  enforces project rules refuses an isolated executor Run
  (`ProjectRulesUnsupportedForIsolatedRun`), which the gate cannot reach.
  The default (`project_rules = .ignored`) reads no bundle, as before.

- **Built-in Kimi Code provider** (#487). `--provider kimi-code` (alias
  `kimi-coding-plan`) uses a Kimi Code subscription: requests go to
  `https://api.kimi.com/coding/v1` (`global-*` channels:
  `https://api.kimi.ai/coding/v1`) and count against the membership, not the
  Moonshot open platform. The key is its own credential kind
  (`kimi_code_api_key`), read from `KIMI_CODE_API_KEY` or `KIMI_API_KEY`.
  The default channel `cn-responses` speaks the Responses wire, as Kimi's
  Codex guide configures it; `cn-chat` and `global-chat` speak Chat
  Completions with the Kimi dialect, which shows the thinking stream. The
  models are the six of Kimi's model page: `k3.1-pro` (the default),
  `k3.1-pro-highspeed`, `k3`, `k3-256k`, `kimi-for-coding` and
  `kimi-for-coding-highspeed`, each with `reasoning_effort` low / high / max
  except the last, which always thinks. `/login` lists "Kimi Code · API
  key": the pasted key is checked by listing the subscription's models and
  stored in `<state root>/keys/kimi-code.json` (0600), as `metacodes login
  --provider kimi-code` does. On Chat Completions the `k3*` models and
  `kimi-for-coding` send no `reasoning_effort` when none is chosen, so the
  server's default applies (high for K3.1 Pro and K3, max for K2.8
  Preview), and never `none`; `kimi-for-coding` sends `reasoning_effort`
  instead of K2.7-code's `thinking` object. K3.1 Pro and K3 declare a
  262,144-token window, the one every plan gets (1,048,576 needs Pro or
  Allegretto). The Anthropic-compatible surface is not offered yet: Kimi does
  not document how a Messages request turns thinking on, and K3.1 Pro
  refuses a request with thinking off. Quotes stay unknown.
- **`SessionHost` resolves model names as the daemon does, when the Host
  asks** (part of #445). With the new `Options.models` (a
  `session_host.ModelPolicy`: a borrowed `model_tiers.TierTable` and the
  provider catalogs' models), a `Submission.model` or `set_model` name is
  trimmed, a tier name (`low`/`mid`/`high`, `haiku`/`sonnet`/`opus`)
  resolves through the Session's provider's tiers, and a model that
  provider does not take (another provider's id, an unset tier) is
  refused: `message_rejected` with `model not available for current
  provider`, or `command_result` with `ModelUnavailable`. The rule
  (`api/model_availability.zig`) is the one `--web`/`serve` messages and
  `/model` use. Without `Options.models` a name is taken as before.
- **`SessionHost` fires a Session's cron prompts** (part of #445). With the
  new `RuntimeConfig.enable_cron`, a Session can select `CronCreate`,
  `CronDelete` and `CronList`; it owns their `CronRegistry`, as the CLI's
  and the daemon's `App` does, and `AgentSession.takeDueCronPrompts` takes
  the prompts due while it is idle. A SessionHost driver checks them at
  most every `cron_poll_ms` (1 s) while its queue is empty, and each prompt
  due becomes a Run typed `session_host`/`cron_fired` whose user message is
  the prompt, as the CLI fires one when it is back at the prompt. A job
  never fires during a Run or ahead of queued work. The cron tools stay out
  of the explicit `builtin_tools` list and the C ABI.
- **A Host sees and cancels a Session's cron jobs without a Run** (#493).
  `SessionHost`'s `Snapshot.cron_jobs` lists them oldest first, each with
  its `id` (a `CronJobId`), `next_fire_unix` and `schedule` (`.once`, or
  `.recurring` with its cron expression), as of the last time the Session
  was between Runs. The new commands `cancel_cron_job` (by id) and
  `cancel_all_cron_jobs` remove jobs in queue order, so they never fire
  again, and are journaled as `command_result` like the other commands; an
  unknown id is `ok: false`, `CronJobNotFound`. `AgentSession` gains
  `cronJobs`, `cancelCronJob`, `cancelAllCronJobs` and `cronDueCount`.
- **Local configuration in the install's `<state root>/.env`** (#486). A
  provider key, `METACODES_PROVIDER` and the new `METACODES_MODEL` can live
  in one file of the install, beside `auth.json`
  (`~/.local/opt/metacodes/state/.env`; `~/.metacodes/.env` for a build run
  from a checkout), instead of the shell profile; side-by-side installs keep
  separate files. It is read once at start, as a layer below the process
  environment, never `setenv`: the shell's value of a name wins, and a key
  in the shell under any of a provider's names hides that provider's keys in
  the file, so the two are never refused as conflicting. It may set every
  registered provider's key names, the variables `config.json` names
  (`providers.<id>.credentials[].env`, `provider_catalogs.<id>.credential_env`;
  these select no provider), `METACODES_PROVIDER` and `METACODES_MODEL`;
  request addresses (`METACODES_BASE_URL`, `METASK_GATEWAY_URL`, any `*_URL`)
  are refused, and every ignored name is listed once in a warning, without its
  value (a line whose name is not written like a variable name, which may be
  part of a pasted key, by its line number only). Its
  provider ranks last: `METACODES_PROVIDER` there (else the one provider whose
  key it holds) applies only when no flag or environment variable names a
  provider, no `/model` default is stored and there is no Metask sign-in
  (`--api-key`, `METASK_API_KEY`, `auth.json`; the file's own
  `METASK_API_KEY` counts only while the file names no other provider); a
  file with keys of several providers and no name stops the run and lists
  them. A key only in the shell
  still never selects a provider, and a `.env` in the working directory or a
  repository is never read. The missing-credential hint and a provider's
  credential help name the file; `metacodes install` and `update` write a
  `.env.example` template beside it and never touch `.env`; `metacodes
  doctor` reports which names the file sets are read or ignored (`--json`:
  `local_config`), never a value. `METACODES_MODEL` in the shell is
  `--model`. Guide: `doc/LOCAL_CONFIG.md`. A `.env` already sitting in a
  state root is read from this release on.

### Fixed

- **A stored default on an OpenRouter model starts when OpenRouter's model
  list is not on this machine** (#622). A model picked in `/model` for
  `from now on` is stored as a pin to its offer, and a start resolves that
  pin against the listing kept in `<state root>/cache/models/`. With no
  listing kept (the cache deleted, `config.json` copied without it), every
  start exited 2 with `the stored selection pins offer …`, and only the REPL
  that could not start would download the listing. Now a start whose pin
  does not resolve, with an OpenRouter key set and no listing kept, says
  `Downloading OpenRouter's model list for the stored default model…`,
  downloads it (30 s at most), keeps it and resolves the pin again. A pin
  is still never remapped: when the download fails, the start exits 2 and
  says why, with `--provider openrouter` to start without that model, or
  `login --provider openrouter` when OpenRouter refused the key. With
  `METACODES_NO_PROBE` set nothing is downloaded, as before.

- **`/login openrouter` no longer stops the TUI while the account's model
  list downloads, and `/model` says how the download goes** (#572). The list
  (`GET /api/v1/models/user`, about 0.8 MB) was fetched on the REPL's thread
  inside `/login`, with no word before it and no time limit: the screen sat
  unchanged until it came. A download that failed still opened `/model`, and
  on an account without credits, preset to `:free`, the picker was empty.
  Now the list downloads in the background and `/model` opens at once; a line
  under its title says `Downloading the models your OpenRouter account can
  use…` with how much has come, a filter that finds nothing yet says the
  models are still downloading, and the list fills in when it comes, the
  filter, the scope and the row under the cursor kept. A download whose
  connection fails, or whose answer stops partway, is tried once more by
  itself; one that still fails, or brings no new byte for 60 seconds, says
  why on that line (`no connection`, `answer cut off`, …) and that Ctrl+R in
  `/model` downloads it again. A refused key says `/login openrouter`
  instead. `/providers refresh` says it is downloading before it waits, and
  `/login` without the TUI downloads before it returns, as before, saying so
  first.

- **A start downloads OpenRouter's model list whatever route the session
  runs on** (#572). With a key set and no list kept, or a day-old one, only a
  session on an Anthropic Messages route with the `/v1/models` probe on
  fetched it; a start with OpenRouter alone, on OpenRouter itself, on an
  OpenAI-wire provider or on a Metask sign-in never did, so `/model` offered
  only `Auto Router`, and a kept list never updated. Every interactive start
  without `METACODES_NO_PROBE` now fetches it in the background; a first
  download is said in `/model` as above, an update of a kept list is quiet.
  A catalog answer cut off partway is now reported as `Interrupted` rather
  than as `TooLarge` or a parse error.

- **Token and cost totals no longer count part of a streamed response
  twice.** A provider reports a response's usage as a running total:
  Anthropic's `message_delta.usage` is cumulative and follows a
  `message_start` that already counted the prompt and the first output
  tokens, some OpenAI-compatible servers attach the usage so far to every
  chunk, and Gemini repeats `usageMetadata`. Each report was added to the
  totals as if it were an increment. On the streaming documentation's own
  examples that is 16 output tokens for a response of 15, and 13361 input /
  513 output for one of 10682 / 510, about 20% more cost. `/cost`, the token
  and cost fields of `--json`, the cost budget, the goal meter and AgentCore
  `usage` events all read those totals. Each provider stream (Messages,
  Chat Completions, Responses, Gemini, Bedrock Converse) now hands on only
  what a report adds to the highest count the response has reported so far,
  so a response's `usage` events add up to the provider's totals however
  many reports carried them. The per-request view behind the context anchor
  and the prompt-cache diagnostics already took the highest report and does
  not change.

- **Behind a proxy, the end of a model's answer is no longer lost, and the
  turn is no longer sent again for it** (#573). Every request to a model
  provider said `connection: close`, so the server closed the connection
  right after the last byte, and behind a transparent proxy that close could
  overtake bytes the proxy had not forwarded yet. On the Responses wire the
  last event is the largest (it echoes the instructions and tools, over
  100 KB), so it was the one cut: the stream counted as incomplete, and the
  turn was sent again and charged again, twice in the TUI and up to four
  times with `-p`. On one proxied route on 2026-11-18 this hit 3% to 23% of
  real streams, and 74% of a large page fetched with `connection: close`
  against none with keep-alive. The Messages, OpenAI-compatible (Chat
  Completions and Responses), Gemini and Bedrock requests, and the Messages
  `/v1/models` list, now say `connection: keep-alive`: the server leaves the
  connection open, and the client closes it once it has read what it needs,
  still without reusing it. A `/v1/models` list cut short no longer reads as
  a complete, shorter one. A stream that ends without its stop report still
  counts as incomplete. A `204` or `304` error answer is reported at once
  instead of being read to the end of the connection. Other requests (MCP,
  TinyKG, sealed skills, the System-One advisor, OTLP export) are unchanged.

- **`/providers remove <id>` no longer leaves a defined provider behind.** For
  a provider defined in `custom_providers` it removed only its settings
  (`providers.<id>`), so the definition stayed in `config.json` and the
  provider came back at the next start. It now removes it whole, as
  `metacodes providers remove` does: the definition, its settings, its stored
  key and login, and a default on one of its models. A built-in vendor still
  loses only its settings.

- **An OpenRouter catalog reads what OpenRouter's API answers today**
  (`src/provider/openrouter.zig`). Fed the live documents of 2026-11-18,
  three things failed: the whole `/models` listing was refused
  (`MalformedPrice`), because OpenRouter prices its router models (such as
  `openrouter/auto`) at `"-1"`, "whatever the model it picks costs" — now an
  unknown price, while any other negative is still refused; an endpoint's
  request named its display string ("Wafer | deepseek/…-20260910") as the
  model, which no request can carry — now the model's own id; and two models
  served by one upstream gave two channels one id (`DuplicateChannelId`), so
  a catalog of more than one model never ingested — an endpoint's channel is
  now named by its routing tag (`deepinfra/fp8` → `deepinfra-fp8`) and holds
  every model it serves. The model bound grew from 512 (478 were listed) to
  4096.

- **`/login` names the providers it cannot list.** Its list holds twelve, and
  the ones past them were dropped without a word; `/login <id>` for one of
  them then showed the list without it. The list now ends with `N more not
  shown: /login <provider> (<ids>)`, and `/login <id>` starts any of them.
- **A provider's own OAuth sign-in is used by a start, and signed out of by
  `logout`.** A sign-in `login --provider <id>` stored in
  `oauth/<provider>.json` reached a session only through a `/model` pick:
  `--provider <id>`, `-p`, and a stored `/model` default on that provider
  found no credential and asked for a key. A start now uses it below every
  key, refreshing it first when it expires within two minutes, and says
  `signed in`; judging a stored default (`login status`, the startup order)
  only checks that the sign-in is stored, so it sends nothing and an expired
  one still counts. `/logout <provider>` and `metacodes logout --provider
  <id>` removed only a stored key; they now remove the sign-in too, revoked
  first where the provider declares an endpoint for it (`oauth_revocation`).
  The help a start prints for a provider that only signs in names `login
  --provider <id>` and no longer offers `--api-key`, and a refused sign-in
  is told to sign in again rather than to check a key.

- **An MCP HTTP request on a kept-alive connection the server closed is sent
  again on macOS too** (#555). A request other than `tools/call` that found
  its pooled connection closed is sent once more on a new one; on macOS, when
  the client read only after the server's reset arrived (a loaded machine),
  the read reported `ConnectionResetByPeer` instead of the end of stream and
  the request failed as `McpOutcomeIndeterminate`. A reset before any
  response byte now counts as that close. A `tools/call` whose body went out
  is still never sent twice.
- **A provider's error answer is shown as it was sent, whatever pieces it
  arrived in** (#565). A non-2xx body that reached metacodes in more than one
  read (the chunks of a `Transfer-Encoding: chunked` body, or a
  `Content-Length` body whose bytes came in apart) came out scrambled in the
  TUI's `HTTP <status>: …` line, the `body=` log line and the failure detail:
  each later piece landed on the start of what had been read, so the first
  piece was lost and the end repeated. OpenRouter's 402 for an account without
  credits was one, and with it went the provider's explanation; an upstream
  error code or the numbers of a context-limit message could go the same way,
  since the failure detail and the overflow check read that text. All four
  provider clients (Anthropic Messages, OpenAI-compatible, Gemini, Bedrock)
  now read the body through one function, `client.readErrorBody`, which gives
  the HTTP reader a buffer of its own; how much of a body is kept (2 KiB on
  Messages, 4 KiB on the others) is unchanged.
- **Shift+Enter inserts a newline while a reply streams** (#456). In the
  terminal UI, Shift+Enter during a reply did what Enter does: the draft
  went into the pending queue, the input box was cleared, and when the reply
  ended the line typed so far was sent as the next message. It now inserts
  a newline in the draft, as it does at the prompt; Enter still queues the
  whole draft, newline included, as one message.
- **A `/model` search can start with `q`** (#599). On an empty filter `q`
  closed the picker, so typing `qwen` closed the list on its first letter
  and left `wen` in the input box: no model whose name starts with `q`
  could be searched for. `q` is now a filter letter like any other, as the
  list's `type to filter` says, and Esc is the way out (it clears the filter
  first). The list no longer shows `q close`, and when no provider is
  configured it names only the ways out with a filter typed too (it said
  `enter apply · tab scope`, though there was nothing to apply). The screen
  that says where a provider's key goes has nothing to type into and still
  closes on `q`.
- **`/model` names the variable and the file for a provider without a key**
  (#483). A route of Kimi (Moonshot's open platform), Gemini, Qwen or MiniMax
  chosen without its key ended in `switch failed (MissingCredentials)`: these
  providers have neither a sign-in nor a key page the picker could open.
  Such a provider is no longer listed (#488), and a pick whose key went
  away after the picker opened shows where it goes: the
  variable to set (the canonical one, e.g. `MOONSHOT_API_KEY`), this
  install's `<state root>/.env` and the guide (`doc/LOCAL_CONFIG.md`); the
  previous route stays active. A picker notice longer than the terminal is
  wide is broken into rows inside the width instead of running past it.
- **An idle AgentCore Session no longer holds about 50 MB of private commit
  on Windows** (#503). Zig 0.16's `std.Thread.spawn` hands its 16 MiB
  default stack to `NtCreateThreadEx` as the stack *commit*, so each thread
  charges 16 MiB of private commit for its whole life; on POSIX it is only a
  reservation. A Session that had streamed one Run kept three: its
  provider's two `std.Io.Threaded` pool workers and the stream liveness
  monitor. Pool workers created through `platform.signal.threadedIo` now get
  a 2 MiB stack (a whole HTTPS exchange peaks at 544 KiB in Debug), and the
  liveness monitor runs on a 256 KiB stack and exits once no request is left
  to watch, coming back with the next one; an idle Session no longer wakes
  every 250 ms either. Measured on Windows 10 x64 with four idle Sessions:
  49,351 KiB and 3 threads per Session before, 4,231 KiB and 2 threads
  after. Every production thread now spawns through
  `platform.thread.spawn` with a named stack class (`waiter`, `io_worker`,
  `full`); the others keep std's 16 MiB as `full`, unchanged. On Linux the
  smaller classes ask for 512 KiB more: glibc carves a thread's static TLS,
  which holds std's 256 KiB alternate signal stack, out of the stack it is
  given, and refuses a thread whose TLS does not fit.
  `zig build test:thread-stack` (part of `test:units`) refuses a direct
  `std.Thread.spawn` outside test blocks.
- **The permission check and the tool read one spelling of a call's
  arguments** (#494). Arguments that named a key twice (`"-i"` twice in a
  `Grep` call, `file_path` twice in a `Read` call) failed the strict parse
  of AgentCore's permission digest, and that failure became a deny: the
  model got `permission_denied` (`safety`, not recoverable) in every
  permission mode, for a mistake it could correct. And `Grep` found its
  `path` by the substring `"path":`, so `"path" : "target.ts"` searched the
  whole working directory while the permission layer judged `target.ts`.
  Now the agent loop admits a call's arguments before the PreToolUse hook,
  the permission check and the tool see them: one JSON object with no
  duplicate key at any level, rewritten in one compact spelling, or an
  `invalid_args` result (`user_error`, recoverable) with nothing run —
  `DuplicateArgumentKey`, or `InvalidArgumentsJson` for arguments that are
  not a JSON object. The bytes the model sent stay in the Conversation
  unchanged. Built-in tools read their arguments as top-level members
  (`tools/common.extractJsonArg`, `util/json.topLevel*Field`) rather than
  the first substring match, so a key nested in another value or inside a
  string is no longer taken for the argument; so do the schema checks
  (`tools.validateRequired`/`validateTypes`), the permission rule matcher
  and the MCP resource tools.

- **Cron prompts no longer push a `SessionHost` queue past `max_queued`**
  (#493). With more jobs due at once than the queue had room for, the
  driver queued every prompt, `Snapshot.queued` went past `max_queued`, and
  `submit` and `command` refused with `QueueFull` until it drained. Now it
  takes only as many prompts as fit, oldest job first; a job left out stays
  due and fires once there is room, so none is lost. A team lead's inbox is
  read under the same bound. `AgentSession.takeDueCronPrompts` and
  `CronRegistry.collectDue` take the limit as a new argument.

- **A run that finds no credential names the command that was run in its
  sign-in hint, and lists the default sign-in first** (#482). Run as
  `metacodes-dev`, a side-by-side development install (`scripts/install.sh
  --dev`) said to run `metacodes login …`, which signs in the release
  install, whose state root is separate; and the list left out the bare
  `metacodes login` that a plain launch reads. The hint now opens with
  `<command> login`, and its other lines, the incomplete-login message, the
  Metask session messages and a named provider's credential help name the
  same command. The launcher `metacodes install` writes now exports its own
  path as `METACODES_LAUNCHER`, because the executable it `exec`s starts as
  `<prefix>/bin/metacodes` for every install. The executable believes the
  variable only when that file is a launcher that execs it; otherwise it
  takes argv[0] (a symlink under another name), then `metacodes`. A
  launcher written before this keeps the hint at `metacodes` until
  `scripts/install.sh` writes it again; `metacodes update` leaves launchers
  as they are.

- **A `CronCreate` with only `delaySeconds` fires once, as the tool says.**
  `recurring` defaulted to true without a `cron` expression too, so the job
  was stored as recurring with no expression to repeat on. After its first
  fire `CronRegistry.collectDue` could not compute the next one and set it a
  minute on, so the "one-shot" prompt ran again every minute until the job
  was 7 days old; in the CLI, after each exchange that ended at least 60 s
  after the last fire. Now `recurring` defaults to true only with a `cron`
  expression, and `recurring: true` without one is refused as
  `invalid_args`, with nothing scheduled; a `cron` or `recurring` sent as
  JSON `null` counts as left out. A recurring job whose next fire cannot be
  computed is removed after it fires, which also stops a valid expression
  with no match within a year (a Feb 29 job after a leap day) from firing
  every minute, and `CronRegistry.create` refuses one, also when
  `delay_seconds` sets its first fire. A delay-only job's tool result now
  says `"recurring":false`; the tool definitions are unchanged.

- **The log-capture tests no longer read another shard's log** (#472).
  `redirect_credential_test` and `http_error_test` logged every capture to
  one fixed file, `<tmp>/cc-zig-<name>-test.log`, which all eight
  `test:integration` shard processes share. A capture in one shard truncated
  or unlinked the file another was logging into, which then read a foreign
  line or lost its own; a merge-queue run failed this way. Each capture now
  creates its own file, named by pid and a per-process counter with
  `O_EXCL` (`harness.LogFile`), and reads it to EOF instead of with one
  bounded `read`; a log larger than the buffer is an error, not a cut.

- **Two tests no longer assume `/bin/sleep` and `/bin/echo` are regular
  files.** Ubuntu 26.04, now GitHub's `ubuntu-latest`, ships the Rust
  coreutils (uutils): `/usr/bin/sleep` and `/usr/bin/echo` are symlinks
  into `/usr/lib/cargo/bin/coreutils/`, to a multi-call binary that acts as
  the command it is run as. There the `process_scan` test looked for its
  `/bin/sleep` child under `/usr/bin`, which the child does not run from,
  and the formal runtime's hash-mismatch test failed with `OpenFailed`
  before its comparison, since `hashChecker` does not follow a symlink.
  Both failed on every run, so `Gates (Linux)` failed for every pull
  request. The first now scans the directory of the program's real path
  and still spawns `/bin/sleep` by that name; the second hashes an
  executable it writes into a temporary directory. Product code is
  unchanged.
- **Signing in to Metask again revokes the sign-in it replaces** (#560).
  `/login`, `/login metask`, `metacodes login` and `metacodes login
  --provider metask` overwrote `oauth/metask.json` and left the session they
  replaced valid at Metask, where nothing on this machine could end it any
  more: `/logout` revokes only the session stored now. Once the new session
  is stored (and, in the TUI, bound), the replaced one is revoked at
  `$METASK_SITE_URL/api/oauth/revoke`, bounded as sign-out (3 s in the TUI,
  5 s on the command line). A refusal or no answer never fails the sign-in;
  one line says the previous sign-in stays valid there until it expires. A
  sign-in that fails, cannot bind or is cancelled revokes nothing; the same
  session imported again is not revoked, and a replaced session whose
  gateway is not the site's origin is not sent there.
- **`/login <provider>` takes effect in a session already on that provider**
  (#566). A route takes its credential when it is chosen, so a key `/login`
  stored afterwards (say, to replace one the provider stopped accepting) was
  never sent: every request still carried the previous key, and failed the
  same way, until `/model` chose the route again. Once `/login <provider>`
  stores a key or a sign-in, a session running on that provider is bound
  again, on the same model, channel and scope, and its next request carries
  what was stored. After a sign-in (OAuth) the process also drops the tokens
  it held from the login replaced: it kept presenting them, even after a
  `/model` pick, and a refresh of them was written over the new login. A
  session on another provider, or on no route, is left as it is.

- **A credential pool member authenticates only its own provider's
  routes.** `config.json`'s `providers.<id>.credentials[]` were read as one
  list for every provider, and a member was chosen by kind alone: a provider
  with no key of its own (DeepSeek, say) was given another provider's member
  whenever its profile accepted that kind, and its requests carried it to
  that provider's endpoint. A route that names an account fell back to
  another credential when that account's variable was unset: another
  account's, the provider's own variable, or a stored key. Each provider now
  reads only its own pool, and a route that names an account uses that
  account or fails with `MissingCredentials`.

- **A `/model` switch that cannot be applied leaves the session's route
  where it was.** The kernel recorded the new route before the session bound
  it and kept it when binding failed (no credential, for instance), and the
  process's OAuth session had already moved to the new provider. The next
  turn's token refresh read both: once that provider's token endpoint
  answered, its token went into the clients still pointed at the previous
  route's endpoint. A failed bind now puts back the kernel's selection
  (journalled as a failed switch, `binding_failed`) and the previous OAuth
  session; a resumed session's stored route is restored the same way.

- **The turn's token refresh renews only the credential the session's route
  was bound with.** It refreshed the provider of the kernel's effective
  selection and put that token in the clients, whatever route they were on.
  After a `/model` pick in the global or once scope (Tab), a narrower scope
  still named the previous route, so a Metask device session that picked a
  relay that way sent the Metask token to the relay every turn; a route
  bound to a pool account or to a key had it replaced by the provider's
  OAuth token. The refresh now follows the route the clients were last bound
  to (before any pick, the one the session started on) and replaces only an
  OAuth token that route was bound with.

- **The Metask token refresh runs only on a route the Metask device sign-in
  authenticates.** The refresh a device-code session installs at startup
  stayed on the clients after a `/model` switch to another provider, so an
  endpoint that answered 401 with `"code":"token_expired"` received the
  request again with the Metask access token. A route switch now installs or
  removes it with the route, and it answers only while the process's OAuth
  session is Metask's.

- **A token refreshed while the route moved is not sent on the new route.**
  When a 401 `token_expired` refresh finished after a `/model` commit (made
  from the reply's key thread) had moved the client, the refreshed token was
  installed and the request replayed at the new route. The client now drops
  it, and the request fails as unauthorized.

- **The `/models` key list is requested only on the Metask API-key route.**
  It was requested with the Metask sign-in token from `auth.json`, at
  `/api/v1/keys` under whatever endpoint the session was on: typing `/model`
  after a switch to another Messages-wire provider, or in a session started
  on one, sent that token there. Elsewhere the menu now shows the list as
  unavailable; leaving the Metask route drops a loaded list, and coming back
  loads it again. A Metask model picked at another Metask gateway (the
  compiled default, say) is still the Metask route.

- **A key picked in `/models` stays on the Metask route.** The pick was
  installed in every client and in the background job registry, and its
  `/v1/models` probe sent, whatever route the session was on. Off the Metask
  API-key route it is now refused (`NotOnMetaskKeyRoute`), and on it only the
  route's own client takes it. The key it replaces stays readable for one
  more pick instead of being freed while a client may still read it.

### Security

- **If you used a relay or switched a session between providers, replace
  your keys and sign in to Metask again.** Before this release a credential
  could reach a provider it was not issued for: after a `/model` switch (a
  relay counts as a provider), the Metask sign-in token, a key picked in
  `/models` or another provider's sign-in token could be sent to the
  endpoint the session was on, and with credentials for several providers
  in `config.json` (`providers.<id>.credentials`) one provider's pooled key
  could be sent to another. Each case is fixed; they are listed under Fixed.
  Create new keys at the providers whose keys this machine held, delete the
  old ones there, and sign in to Metask again with `/login` or
  `metacodes login`, which now revokes the sign-in it replaces (#560).
- **On `serve` and `--web`, an answer from before a restart no longer
  answers a newer request** (#563). Both numbered UI requests from 1 in every
  process, and again for every session they restored, and `POST /respond`
  and the UDS `respond` op matched an answer by that number alone. So an
  answer delivered a second time after a restart was applied to whichever
  request held the same number then. That happened with a webhook that
  retries, a client that reconnects, or an old card clicked again. One
  Write's approval approved another Write, and the journal recorded the
  original approver for it. Request ids now come from one counter per
  process that stays above the wall clock in milliseconds, so they are never
  reused, across restarts or for a session destroyed and restored. Such an
  answer is refused as stale: 409, or the UDS `no pending request with this
  id`. Ids are larger integers now, about 1.8×10¹² and below 2⁵³; a frontend
  copies them back as before. `tests/component/serve_sessions_test.zig`
  restarts the daemon between one granted Write and the next, then delivers
  the first approval again; `src/web/backend.zig` checks the same across two
  `WebBackend`s.
- **An MCP tool asks before it runs on the CLI hosts, as on AgentCore**
  (#473). The TUI, `-p`, `--web` and `serve` permissioned a tool an MCP
  server contributes as a read, so `default`, `acceptEdits` and `auto` ran it
  on the model's decision alone: a tool that changes something outside the
  machine (a database, a ticket system, a deployment, a device) ran without a
  prompt, and text the model read in a web page, a file or another tool's
  output could steer it there. AgentCore already permissioned the same tool
  as executing and asked. Every tool a server lists is now permissioned as
  executing, as `Bash` is: `default`, `acceptEdits` and `auto` ask before it
  runs (`-p`, with nobody to ask, denies it), `dontAsk` denies it, and
  `bypassPermissions` runs it. A server's annotations (`readOnlyHint` and the
  rest) are its own claim and do not relax this. To keep a trusted server's
  tools running without a prompt, allow the server:
  `{"permissions": {"allow": ["mcp__<server>"]}}` in a settings file
  (`mcp__<server>__*` and `mcp__<server>__<tool>` work too), or
  `--allowedTools mcp__<server>`. Approving a project server in `.mcp.json`
  only starts it. `ListMcpResourcesTool`, `ReadMcpResourceTool` and the
  Skill tool keep their classification.
  `tests/component/mcp_permission_test.zig` runs a real App against the
  stdio mock server in every mode and under each spelling of the allow rule,
  and checks what the server received; `tests/tty/cases/test_mcp_permission.py`
  checks the TUI's dialog.

## 0.12.0 — 2026-11-13

### Changed

- **Breaking: the `--web`/`serve` event stream is wire v1 throughout** (#444).
  `/events` and the UDS `attach` op carried two envelopes. Kernel events and
  UI requests were versioned wire lines, but the host lines were unversioned
  `{"<name>":...}` objects written by hand, with their own field names and no
  Run identity. Now every journal line is one wire v1 line written by
  `core/protocol/wire.zig`, in the form `SessionHost` writes
  ([doc/WIRE_PROTOCOL.md](doc/WIRE_PROTOCOL.md) §1.1–1.2). `user_message`,
  `run_done`, `command_result` and the new `message_rejected` are host
  events (`{"v":1,"type":...,"data":{...}}`), and `session_lifecycle` is a
  kernel event. `run_done.err` is gone: a failed Run names its error in
  `error_name` with a `null` `stop_reason` (it said `"error"`), and a model
  failure's text is `model_error.message`. `command_result` gains `command`
  (the line's verb) and `error_name`, and keeps its text in `message`. Runs
  are numbered per session, and `user_message`, `run_done` and every kernel
  event in between carry the Run's `run_id`. A `/command` that plans a Run
  journals its `command_result` before the Run's `user_message`. Out-of-tree
  readers of `/events` and `attach` switch on `type` and read `data`; the
  bundled browser UI parses this one form. The UDS frames
  `{"type":"keepalive"}` and `{"type":"session_closed"}` stay as they were:
  they are the transport's, not journal lines (§1.3). For the wire contract
  the change is additive: `message_rejected` is a new HostEvent tag, and
  `command_result.message` an appended field
  (`tests/fixtures/wire/v1/host_events.jsonl`).

- **`--web` and `serve` refuse an `idempotency_key` instead of ignoring it**
  (#447). A message carrying one was accepted and the key dropped, so a
  retried delivery ran twice while its client believed it was de-duplicated.
  `POST /message` now answers `400` and the UDS `message` op
  `{"ok":false,...}`, both with `idempotency_key not supported: this host does
  not de-duplicate messages`, and nothing is queued; `"idempotency_key":null`
  still counts as absent, and other unknown fields are still ignored. These
  hosts take keys once they run on `SessionHost` (#445).

### Added

- **Typed submissions and a bounded inbox on `SessionHost`** (#447).
  `Submission` gains `source`, `kind`, `attributes` and `idempotency_key`. One
  key is one Run: a delivery whose key is queued, running, or whose Run
  started within `Options.idempotency_retention_ms` (24 h) is refused with
  `error.DuplicateSubmission`, and the same key on a different submission with
  `error.IdempotencyKeyReused`. Started keys are kept in the session
  directory (`idempotency.jsonl`), so a Host that reopens the Session after a
  restart refuses them too; a key is spent only when its Run starts, so a
  delivery the restart dropped from the queue may be sent again. A full queue
  refuses with `error.QueueFull` after duplicates are answered and holds
  nothing, and `Snapshot.max_queued` reports the bound next to `queued`.
  `source`, `kind`, `attributes` and the key are echoed on the Run's
  `user_message`, as appended fields written only when given, so other lines
  keep their bytes (`tests/fixtures/wire/v1/host_events.jsonl`). They reach
  the provider only through `OpenSpec.submission_template` (`{{text}}`,
  `{{source}}`, `{{kind}}`, `{{attributes}}`); without one the provider
  receives the text's bytes, as before. `serve` and `--web` take typed
  submissions once they run on `SessionHost` (#445).

- **A stream retry budget for AgentCore Hosts** (#452). A reasoning model
  streams thinking first, so a gateway stream that breaks off has almost always
  shown output, and the Run ended with `STOP_API_ERROR`. AgentCore ABI revision
  28 adds `RunOptionsV1.stream_retry_budget` (0 to 8, default 0, in the
  options' last reserved word): the Run may send the same request again that
  many times when its accepted stream broke off without an answer (a stall, a
  dropped connection, a stream that ended before its stop report), beyond
  each request's own re-send (#461); a server's error and a local decode
  failure are never re-sent. Each re-issue tells the Host what to take back:
  the attempt's segment closes `discarded`, the new `thinking_discarded` event
  names the thinking it showed, and a `retry_notice` follows. The header, the
  bindings, the Python (`stream_retry_budget=`) and Node (`streamRetryBudget`)
  packages and the source-free consumers move to revision 28.

- **Edit and rerun through AgentCore** (#441). AgentCore ABI revision 27 adds
  `session_control->rewind_to_user_message(session, position, out_error)`, the
  operation behind `/edit` (#432): while idle it drops the user message at a
  1-based position and everything after it, and the Host's next Run takes its
  place after exactly the context before it. A position that cannot be rerun is
  refused with its own status (31 `MESSAGE_POSITION_OUT_OF_RANGE`, 32
  `NOT_USER_MESSAGE`, 33 `MESSAGE_POSITION_COMPACTED`) and changes nothing. Only
  the Conversation changes; a checkpoint exported afterwards holds the edited
  history and a restored Session continues from it. The Session Control table
  grows to 88 bytes. The header, the Zig and Rust bindings, the Python
  (`Session.rewind_to_user_message`) and Node (`Session.rewindToUserMessage`)
  packages and the source-free consumers move to revision 27; AgentCore
  0.15.0-dev.
- **A `SessionHost` submission may carry its own `model` and
  `permission_mode`** (part of #445), as a `--web`/`serve` message does.
  The driver applies them just before the Run, journaled as the
  `command_result` of `set_model` and `set_permission_mode`, and they stay
  the Session's settings. The mode is checked first, so when either is
  refused nothing is applied, no Run starts and `message_rejected` (now
  written by both Hosts) takes the place of `user_message`, naming the
  error; the submission's idempotency key is not spent. Before, an
  embedder had to queue the two commands itself and could not refuse the
  text together with them.

- **`SessionHost` feeds a team lead its teammates' replies** (part of #445).
  A lead Session (`SessionConfig.team` with the lead role) hosted on
  `core/session_host.zig` never saw a member's `SendMessage`: the inbox is
  driver-owned state, so no Host thread could read it safely, while the
  bundled daemon's `App` lead takes each reply as its next turn. Now the
  driver of an idle lead whose team exists reads the lead inbox at most every
  `session_host.lead_inbox_poll_ms` (500 ms, the daemon's interval) and queues
  the reply as the lead's next Run, journaled like any other (`user_message`,
  kernel events, `run_done`). This is the first of the `App` dependencies the
  daemon needs an `AgentSession` counterpart for before it can run on the one
  `SessionHost`. `zig build subsystem:boundary` now also holds that move to a
  ratchet: no file under `src/daemon/` or `src/web/` may import
  `src/core/agent_loop.zig` beyond the two that do today
  (`daemon/app_driver.zig`, `web/session.zig`), and a baseline entry whose
  import is gone fails until it is deleted.
- **`SessionHost` starts a hosted lead's teammates** (part of #445). A lead
  hosted on `core/session_host.zig` could ask for a teammate
  (`SpawnTeammate`), but the request only sat in `pending_spawns`, while the
  bundled daemon's `App` starts its teammates itself. With the new
  `session_host.Options.teammates` (a `TeammateFactory` the Host supplies
  for the member's provider, workspace, tools and permissions), the lead's
  driver now opens each requested member on the same `SessionHost` under the
  lead's team identity and a fresh lease, and submits the request's prompt
  as the member's first Run; the member's reply comes back as the lead's
  next Run, and closing the lead closes its members. Without a factory
  nothing changes. `SwarmContext.popPendingSpawn` hands a request over with
  its ownership.
- **`SessionHost` teammates inherit their lead, re-spawn, and fail visibly**
  (part of #445). The new `session_host.InheritLead` is the `TeammateFactory`
  the bundled daemon needs: each member gets the Host's base configuration
  with its lead's current model and permission mode, and the spawn's effort
  or else the lead's reasoning effort, as an `App` teammate inherits its
  lead's. `TeammateSpawn` now carries those lead settings
  (`lead_model`, `lead_permission_mode`, `lead_reasoning_effort`), read on
  the lead's driver after the commands queued before the spawn. A name whose
  member the Host closed is opened again: its old roster entry, which held
  the old lease and refused the new member, is dropped first, so the new
  member joins under a fresh lease and the closed one's mail stays
  unaddressed. A spawn that fails is no longer only logged: it becomes the
  lead's next Run, `<teammate-status from="<name>" state="failed">teammate
  was not started: <error></teammate-status>`, journaled as a typed
  `user_message` (`source` `session_host`, `kind`
  `teammate_spawn_failed`); a member that was open but refused the prompt
  reads `teammate did not take the prompt: <error>`. Reports do not chain:
  a failure while fulfilling a report Run's own spawns is only logged, so a
  model that keeps re-spawning a name that cannot start costs one extra Run,
  not one per retry.

- **The UDS binding answers UI requests and takes capability frames.** A
  UDS-only frontend needed HTTP beside the socket for exactly the most
  important exchange, the reverse requests; now
  `{"op":"respond","session":"<id>","id":N,...}` answers the pending
  `ui_request` N with the same answer fields `POST /respond` takes (a stale or
  unknown id is refused, the HTTP surface's 409; an answer is parsed by
  `wire.parseResponse`, so a malformed one is never a grant), and
  `{"op":"capabilities","session":"<id>","v":1,"type":"capabilities",...}` is
  the capability frame itself beside the routing fields, answered with the
  same acknowledgement line as `POST /capabilities` and journaled for every
  attached reader. doc/WIRE_PROTOCOL.md §2.3 and doc/API.md spell the ops out.

- **UI requests on long-lived Hosts: who answered, what an unanswered one
  gets, and questions that survive a restart** (part of #446). An answer may
  name its approver, `"by"`; the request's `ui_request_closed` records it,
  appended after `outcome` only when given, so other lines keep their bytes
  (`tests/fixtures/wire/v1/requests.jsonl`). `SessionHost.respond` refuses a
  `by` that is not 1 to 256 bytes of string (`error.InvalidApprover`) and a
  second answer to a request whose first is not applied yet
  (`error.AlreadyAnswered`); `--web` and `serve` record a valid `by` as well.
  `SessionHost.Options.ui_request_expiry` says what a request
  `ui_request_timeout_ms` leaves unanswered gets: `.cancel` (the default, as
  before), `.interrupt` (the Run stops too; an expired permission prompt
  still reads as unanswered in time, doc/WIRE_PROTOCOL.md §1.4) or
  `.re_announce` (the same `ui_request` line again every period, so a zero
  timeout is refused, `error.InvalidUiRequestTimeout`). Work queued while a
  request is open waits behind it, and `Snapshot.queue_waiting` says why. With
  `Options.ui_request_wait = .suspend`, a question or custom UI request ends
  its Run `suspended` instead of holding the driver: the Session's directory
  keeps it, `close` leaves it there, `open(.resume)` announces it again under
  its id after a restart, and `respond` resumes the Run once through the new
  `AdmittedRun.resumeWithResults`, journaled with the new host event
  `run_resumed`; the resumed Run keeps the suspended Run's trace id, turn
  limit and stream retry budget, and request ids are never reused. Each
  answer reaches only the request it names, and a suspended Run's
  idempotency key stays spent while it waits. Nothing
  else runs while a Run is suspended, and a suspended team lead leaves its
  inbox unread until it resumes. Permission
  requests still block in that mode: the kernel's permission gate reads a
  `pending` answer as a denial, so making them survive a restart needs the
  kernel to suspend there first (follow-up). doc/WIRE_PROTOCOL.md §1.5,
  doc/API.md.

### Fixed

- **A cancelled question no longer poisons its `SessionHost` Session** (part
  of #446). A question the timeout, an interrupt or an unreadable answer
  cancelled reached the AgentSession as `InputAborted`, which it takes for a
  broken Host: the Run failed `CallbackFailed` and the Session reported
  `session_poisoned`. It now gets `UiCancelled`, the user's outcome, so the
  call fails with `InputAborted` as the model sees it and the Run and Session
  go on. A cancelled custom UI request still poisons; that needs the
  AgentSession to tell the two apart for custom requests too.

- **A permission prompt nobody answered no longer reaches the model as
  "user declined"** (#463). A `SessionHost` timeout, an interrupt or close, an
  unreadable answer, a requester that answers `pending` or `unavailable` or
  fails, and a headless run with nobody to ask each read as what happened
  ([doc/WIRE_PROTOCOL.md](doc/WIRE_PROTOCOL.md) §1.4); a timeout or a
  cancellation is `recoverable: true`. Every case still denies with `code`
  `permission_denied`, and a person's deny keeps its exact bytes. For Zig
  Hosts: `wire.cancelResponse(request, why)` replaces
  `cancelResponse(request, out)` and fails a permission prompt with a
  `ui_request.Unanswered` error instead of answering `deny_once`;
  `wire.parseResponse` returns `void` and fails an unreadable permission
  answer with `UiAnswerUnreadable` (journal it with
  `wire.closedOnParseError`). Wire lines are unchanged.

- **A model request is retried once after a transient stream interruption,
  even after partial output** (#461). A gateway stream that returned HTTP 200,
  streamed some text or thinking and then dropped ended the Run with
  `api_error` (`stream_interrupted`, `retryable`, `attempts=1`) in the TUI,
  headless mode and AgentCore alike: the one automatic re-send applied only to
  an attempt that had shown nothing and was shared across the whole Run, and
  #452's re-send after output defaulted to zero. Now every model request has
  one re-send of its own (`agent_loop.STREAM_RETRIES_PER_REQUEST`), so an
  earlier turn cannot use it up. It applies when the connection gave no
  answer (a stall, a drop, a stream that ended before its stop report) and the
  failed response had not started a tool call: each client's parser reports a
  call whose arguments were still streaming (`StreamHandle.toolCallStarted`),
  which the loop never received. The attempt's text and thinking are
  discarded, the identical request goes to the same provider, wire, model and
  binding, and results of tools that completed on earlier turns stay. A
  re-send of an attempt that showed output emits `retry_notice` (after the
  `discarded` segment and, for thinking, `thinking_discarded`) and waits
  500 ms; an abort during the wait ends the Run `aborted` and sends nothing.
  A server-declared error, a local parse failure and a cut during a tool call
  are still single-attempt. `max_stream_turn_retries` (headless) and the
  AgentCore budget now come on top of the request's own re-send.

- A same-turn re-issue no longer looks up the abandoned attempt's speculative
  tool results: they borrowed the attempt's freed tool-call ids, and a
  re-issued call with a repeated id could take a released, empty result
  instead of running. Reachable before through headless retries after a
  streamed tool call (#452).

- **metacodes-core's isolation from the application is checked** (#448).
  `src/lib.zig` claimed its import graph could not reach the UI and that
  `test:lib` proved it, but lazy analysis skips imports in code nothing calls,
  and nothing noticed a planted `core/` → `repl/tui/` import.
  `zig build subsystem:boundary` now follows every `@import` from
  `src/lib.zig`, function bodies and test blocks included, and fails on any
  edge into `repl/`, `web/`, `daemon/`, `app/`, `main.zig`, `app.zig`,
  `session_service.zig` or `session_intent.zig` outside a baseline that may
  only shrink: a stale entry fails too, and `src/core/` has none. The model
  context-window table moves from `src/app/` to `src/api/model_context.zig`,
  removing seven of the eleven edges; the baseline holds the other four.

- **A stream that ends before it says how it stopped is reported as an
  interrupted stream** (#451). When an accepted stream ended cleanly without
  its stop report (no `message_delta.stop_reason` on Messages, no non-null
  `finish_reason` on Chat Completions, no terminal event on Responses, no
  `finishReason` on Gemini, no `messageStop` on Bedrock), the Run's
  `model_error` said `category: unknown`, `retry: unknown` and "The response
  stream could not be read: StreamIncomplete." It now says
  `stream_interrupted` and `retryable`, with that response's status and request
  id and the message "The response stream ended before it reported how it
  stopped.", as the ABI already documented and as Core's same-turn retry
  already treated it. The retry, the attempt count and the empty detail after a
  retry that succeeds are unchanged; a local decode failure such as an
  oversized SSE line stays `unknown`.

- **A provider that compresses its answer no longer breaks the request**
  (#467). A std.http request offers `accept-encoding: gzip, deflate` by
  default and accepts either in the response head, but every body in `src/`
  is read as sent: `Response.reader` and `Reader.bodyReader` do not decode.
  DeepSeek takes the offer, so its SSE reached the line reader as gzip, no
  event parsed, and every attempt ended as `StreamIncomplete` (the Run as
  `api_error`). The four streaming model clients (Messages, OpenAI-compatible,
  Gemini, Bedrock) no longer offer it (#468). And every request in `src/`,
  which sends through `api/http_connection.zig`, now accepts the identity
  coding only. A request that left the header at std's default says
  `accept-encoding: identity`, as the OAuth, telemetry and catalog requests
  do. A server or gateway that compresses anyway fails in `receiveHead`
  (`HttpContentEncodingUnsupported`) instead of handing gzip to a parser.

### Security

- **A Grep pattern can no longer act as a ripgrep option** (#460). Grep is
  read-only, so `accept_edits` runs it without a prompt and
  `ShellPolicy.disabled` keeps it available. Both of its execution paths, the
  direct one and the artifact-capture one that AgentCore uses, and every retry
  passed `pattern` to ripgrep as a separate argument. A pattern that began with
  `-` was read as a flag, and `--pre=<program>` made ripgrep run that program
  on every file it searched, with no approval for running a command. Both
  paths and every retry now build their arguments with one function. The
  pattern goes in only as the value of `--regexp=`, the search path comes
  after `--`, and every other value the model supplies is joined to its flag
  in a single argument (`--glob=…`, `--type=…`, `--context=…`). A
  leading-dash pattern now matches its literal text. Two other tools passed
  model text to ripgrep the same way, and they are fixed too: FindSymbol's
  `name` (now `--regexp=` plus `--`), and Glob's pattern and path (now
  `--glob=` plus `--`). CodeMap's glob now joins its flag in one argument as
  well. `tests/component/grep_option_injection_test.zig` runs the
  repository-pinned ripgrep, after checking its digest, against both paths.
  It checks that a `--pre=<script>` pattern returns the literal line on both
  paths and with an `artifact_id`, and that the script never runs. It reads the
  result back from the artifact store and checks ordinary regex, `-i`, glob
  and type filters, context, and line numbers in file and directory searches.
  It also checks that `accept_edits` still allows Grep while a denied Bash
  request for the same script leaves no trace.

## 0.11.0 — 2026-11-06

### Added

- **Amazon Bedrock, native** (#423). A
  `bedrock_converse` wire: Converse requests, answered with the AWS event-stream
  binary framing (both CRCs checked) rather than SSE. `--provider bedrock`
  (alias `aws-bedrock`) has one channel per region, each naming the inference
  profiles its region can call (Tokyo: `jp.` Sonnet 4.6, `global.` Opus 4.6),
  and authenticates with a Bedrock API key (`AWS_BEARER_TOKEN_BEDROCK`); access
  keys, SigV4 and AWS profiles are not supported, and the missing-key help says
  so. Claude on Bedrock gets the thinking contract of its generation (Opus and
  Sonnet 5.5, Fable and Mythos are never sent `disabled`; 3.7 and 4.0 – 4.5 get
  a budget between 1,024 and `maxTokens`; Claude 3.5 gets none), never thinking
  beside `temperature`, `topP` or a forced tool choice, and cache points after
  the system prompt, the tools and the conversation. The signed reasoning of a
  tool turn is kept in the conversation, so it goes back unchanged on the next
  request, after a resume too. Requests share the other wires' lifecycle:
  connect retry, 429/5xx retry, context-limit recovery, Aborted on cancel; an
  exception frame carries its category and message, and a frame cut by a closed
  connection is retried as an incomplete stream. An account's own catalog
  (ListFoundationModels and ListInferenceProfiles) is ingested the way
  OpenRouter's is: `provider_catalogs` with `"kind": "bedrock"`, one offer per
  usable model and inference profile, each declaring its dialect from the
  catalog's `providerName`. `model_tiers` takes a `bedrock` key. A Bedrock
  session cannot run sealed Skills: SSP/1 has no provider kind for it.
- **Built-in DeepSeek, Kimi, Qwen and MiniMax providers.** `--provider deepseek |
  kimi | qwen | minimax` with the vendors' China and global channels on both the
  OpenAI and Anthropic wires, each route declaring the vendor's dialect, limits
  from the vendors' own documentation, and reasoning controls in the vendors'
  vocabularies. Keys come from `DEEPSEEK_API_KEY`, `MOONSHOT_API_KEY`,
  `DASHSCOPE_API_KEY` and `MINIMAX_API_KEY`. Quotes stay unknown (time-of-day,
  regional and tiered prices). On the Anthropic wire each vendor has its own
  dialect rather than Claude's: Qwen sends `thinking` `enabled` / `disabled` and
  its `low` / `medium` / `xhigh` effort, Kimi only `output_config.effort` in
  `low` / `high` / `max`, MiniMax `adaptive` / `disabled` (M3 explicitly, since
  it does not think on that wire unless asked) with an effort for M3.1. Kimi
  K2.7-code is offered on the OpenAI channels only, and Kimi K3 and K2.7-code
  leave a `temperature` / `top_p` override out, as their documentation asks.
  Qwen 3.8's window and output limits are recorded as unverified: Model
  Studio's own pages do not state them.
- **A route says which vendor dialect it speaks.** `ProtocolRoute.dialect` and
  `ModelEntry.dialect` (and `"dialect"` on a `custom_providers` channel or model)
  name the vendor whose parameters the request carries, the way an OpenRouter
  endpoint names its upstream. The declaration travels with the route's auth
  scheme to the session, a `/model` switch, child agents, swarm teammates and
  `AgentSession`. A route that declares nothing keeps model-name inference, so
  existing configurations behave as before; an unknown value fails the definition.
  A model's declaration covers that model only: a child agent, teammate or
  Session model switch onto another model of the same route keeps the route's
  declaration or infers from its own name.
- **OpenRouter's own request surface.** Offers ingested from an OpenRouter catalog
  declare the new OpenRouter dialect: `reasoning: {effort}` and `delta.reasoning`,
  whatever the upstream model is called. A `deepseek/...` model through OpenRouter
  no longer gets DeepSeek's native `thinking` fields. OpenRouter routes' request
  bytes change once, so their provider-side prompt cache misses on the first
  request after the upgrade.
- **Edit and rerun.** `/edit <n> <text>` edits message `n`, one you wrote,
  and reruns from it: the conversation becomes messages `1..n-1` plus the new
  text, and everything after the original message (later prompts, replies,
  tool calls and results) is dropped. The transcript is rewritten, so a
  resumed session restores the edited history. Only the conversation changes;
  files and other effects stay. A message that is not yours, out of range, or
  compacted into a summary is refused by name (`NotUserMessage`,
  `PositionOutOfRange`, `PositionCompacted`) and nothing changes. `/edit`
  alone lists the editable messages. Web and daemon take the line over
  `POST /command`; Zig Hosts use `AgentSession.rewindToUserMessage` or
  `SessionHost`'s `Submission.replaces`, and the wire `user_message` line
  gains `replaces` ([doc/API.md](doc/API.md#edit-and-rerun)). (#432)

### Changed

- **One integration file per model vendor.** The OpenAI-compatible dialects that
  shared `src/api/dialects/openai.zig` (GLM, Kimi, DeepSeek, Qwen, MiniMax,
  Mistral) each have their own file, next to OpenAI, Claude and Gemini. The header
  of each file is that vendor's integration document — endpoints, wires, thinking
  parameters and the effort mapping, reasoning passback and caching, known
  differences, and the dated vendor pages it was checked against — and a test fails
  when a section is missing. Model-name recognition is unchanged.
- **Thinking parameters re-checked against the vendors' current documentation**
  (2026-11). MiniMax M3 now sends `thinking.type: adaptive` instead of `enabled`
  (the API accepts only `disabled` / `adaptive`), M3.1 sends its `reasoning_effort`,
  and every MiniMax model asks for `reasoning_split`. Kimi K2.6 no longer puts an
  `effort` in its `thinking` object, and K2.7-code never sends `disabled`.
  DeepSeek's `low` level is sent as `low` rather than `high`. A Kimi model id
  that names no generation (`kimi-latest`, `kimi-for-coding`) is now treated as
  K2.7 or later: thinking stays on, and `none` no longer sends `disabled`.

### Fixed

- **DeepSeek, Kimi and MiniMax get their reasoning back.** DeepSeek answers 400
  when a request with tools lacks the `reasoning_content` of earlier turns, Kimi's
  documentation requires it with tool calls, and MiniMax M3 and later ask for the
  full response back to keep the reasoning chain; none was ever sent. The
  conversation's thinking blocks now reach the dialect, and a dialect that
  declares passback (`ModelProfile.echoes_reasoning_content`: DeepSeek, Kimi,
  MiniMax M3+, OpenRouter) sends them as `reasoning_content` on assistant history
  — or, on a route declaring DeepSeek on the Anthropic wire, as its non-empty
  thinking blocks. Every other dialect's request bytes are unchanged; Claude
  never receives an unsigned thinking block. A custom DeepSeek Anthropic endpoint
  gets its thinking back only when it declares `"dialect": "deepseek"`.
- **Mistral reasoning is requested, read and sent back (#437).** The Mistral
  dialect sent no reasoning control and looked for reasoning only in a flat
  `reasoning_content`, which Mistral never returns. Mistral streams reasoning as
  ThinkChunks inside a list-typed `delta.content`, and the list at the switch to
  the answer also carries the first answer text, so both were lost. The dialect
  now sends `reasoning_effort` in each model's documented vocabulary: Small 2603
  and Medium 3.5 take `none` / `high`; Large 4 takes `low` / `medium` / `high`,
  so a neutral `none` goes out as `low`. Magistral (always reasoning) and
  models whose reasoning Mistral does not document (`mistral-large-latest` is
  Large 3) get no effort field. On the Mistral dialect only, the OpenAI chat
  stream parser reads a list-typed `content` in order: a text chunk is answer
  text, a thinking chunk's text is reasoning. Assistant history with reasoning
  goes back to Mistral's reasoning models as ThinkChunks in a list-typed
  `content`, as Mistral asks. Those requests change bytes, so their
  provider-side prompt cache misses once after the upgrade. Every other route's
  request bytes and parsed streams are unchanged, including a route that
  declares another dialect for a Mistral-named model.
- **Kimi K2 with no reasoning effort set no longer crashes.** On the OpenAI chat
  wire the K2.6 dialect unwrapped the unset effort while writing the `thinking`
  object, which panicked in Debug and ReleaseSafe builds; it now sends
  `{"type":"enabled","keep":"all"}`.
- **The x86_64 macOS release unit no longer fails its CPU baseline check on a
  jump table.** This is why 0.10.0 was tagged but never published: release run
  41194755285 built every unit but stopped at `scripts/check_binary_baseline.py`
  on the x86_64 macOS executable, which it said held one AVX-512 instruction,
  so no draft release was made. The executable has no such instruction. The
  six bytes were two entries of the jump table for `repl.loop.readLineRaw`'s
  key switch. LLVM keeps such tables inside `__text` on x86_64 macOS, and the
  linker lists them in `LC_DATA_IN_CODE`. A linear `objdump -d` decoded them as
  code. 0.9.0's unit had 486 such tables, and none happened to decode as a
  vector instruction. The check now disassembles a Mach-O in llvm-objdump's
  Mach-O mode, which prints those ranges as data, over every section that
  holds instructions. It fails unless every listed range came back as data and
  no instruction starts inside one. The macOS `release` leg of `ci.yml` now
  builds both macOS units for their release targets and runs the check on
  every change, not first at release time.
- **Plain headless says why a failed Run stopped (#417).** `-p` without `--json`
  exited 1 with nothing on stderr when the reply was still cut off after the
  three max-token continuations, and when the Run was interrupted by SIGINT or
  SIGTERM. Those stops, and the same exit for a tool failure, now write one
  `error: stopped (<stop_reason>): …` line to stderr, on `--resume-response`
  too. Stdout (any partial text) and the exit code are unchanged, and so is
  `--json`.
- **One provider request lifecycle (#434).** OpenAI Chat Completions, OpenAI
  Responses and Gemini retry a transient connect failure, a 429 or a 500/502/503
  before the response head with the Anthropic client's policy (attempt limit,
  backoff, Retry-After, retry notice). A cancel while the head is awaited is
  `Aborted` on every provider, and an HTTP context-limit rejection is
  `ContextWindowExceeded`, so the agent loop's context recovery runs.

## 0.10.0 — 2026-10-31

### Changed

- **One MCP client.** The CLI, source-level consumers and AgentCore now run one
  protocol implementation (`src/mcp/client.zig`); AgentCore's separate client,
  negotiation driver and the CLI's hand-written frame parser are gone. What
  separates the entry points is an explicit, tested profile
  ([doc/MCP_ARCHITECTURE.md](doc/MCP_ARCHITECTURE.md)). No ABI or supported-version
  change.
  - **CLI:** a tool's `isError` is a tool error at every size, and a `tools/call`
    without `content` is accepted at every size. Both used to depend on whether the
    frame was over 1 MiB.
  - **CLI:** a `tools/call` is never sent twice once its body went out, including on
    a reused HTTP connection that closes unanswered. The model is told the call may
    have executed. Such a call does not reuse a connection idle for over a second.
  - **AgentCore:** the byte-zero path accepts escaped control characters in a
    result's content, as its materialized path did.

- AgentCore now ships with every release under its own final version, with its
  Python wheel and Node package, instead of a `-dev+<commit>` archive. The cut
  selects and finalizes the version, and an unchanged AgentCore keeps its version
  and artifacts. Release notes name it. `sdk/agentcore-releases.json` maps each
  version to its ABI revision, and the release workflow refuses development
  versions, version or ABI mismatches, and any artifact that differs from a
  published one of the same name
  ([doc/RELEASE_AUTOMATION_DESIGN.md](doc/RELEASE_AUTOMATION_DESIGN.md) §2a). (#404)

### Fixed

- The AgentCore bundle README stated ABI revision 18 and a 64-byte root. It now
  takes the revision, root size and tables from the ABI types. (#404)
- **A server that repeats your key no longer gets it into the log or onto the
  screen (#408).** The credential a request carried, and known secret shapes, are
  now masked in the log and the TUI's error line for redirect URLs, error frames
  inside a stream and HTTP error bodies, on all three provider clients and outside
  a Run too; the structured detail already masked them. Part of a credential cut
  by a read limit is dropped, and a redirect URL at the limit is not quoted. The
  `body=` log line now has control bytes flattened, secret shapes masked and a
  limit of 8 KiB. Debug logging of full responses is unchanged.

### Added

- **Model failures say why (#408).** A Run that stops with `api_error` now
  reports structured detail for that Run: a general category, the upstream's
  code and type passed through verbatim, a redacted, size-limited displayable
  message, HTTP status, request id and retry guidance, with `unknown` when it
  cannot be determined. AgentCore delivers it as a `model_error` event before
  the terminal `run_state` (additive: Revision 26, `STATUS_OK` and
  `STOP_API_ERROR` are unchanged), the Python and Node SDKs as
  `result.model_error` / `result.modelError`, the web and daemon completion
  line as `run_done.err` and `run_done.model_error`, and `SessionHost` on its
  `run_done`. The OpenAI and Gemini clients now keep the error body they used to
  drop. No billing or quota logic was added: an unrecognized code is passed
  through and makes retry guidance `unknown`.
- **OpenTelemetry tracing and a web trace view.** Every Run is recorded as a
  span tree following the GenAI semantic conventions (`invoke_agent` →
  `turn` → `chat <model>` / `execute_tool <name>` / `compact`), with token
  usage, permission decisions, cache breaks and compaction on it
  ([doc/OBSERVABILITY.md](doc/OBSERVABILITY.md)).
  - **Export:** the standard `OTEL_*` variables send the spans to any
    OTLP/HTTP collector, `http/protobuf` (default) or `http/json`, from a
    batching exporter thread that is flushed at exit. Message content is
    exported only with `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true`.
  - **Session store and web view:** the spans are also appended to the
    session's `spans.jsonl`; `--web` and `serve` serve them as OTLP/JSON at
    `GET /spans` and as a waterfall of the whole conversation at `GET /trace`
    (linked from the chat page). `METACODES_SPANS=off` turns the store off.
  - Tool spans are recorded for every frontend, including those that do not
    render tool cards (headless).

## 0.9.0 — 2026-10-29

### Added

- **`/terminal-setup` binds Shift+Enter to a newline in Apple Terminal and VS
  Code** (#386, part 1). Neither reports Shift+Enter on its own (Apple Terminal
  has no keyboard protocol; VS Code's xterm.js is on its deny-list), so there
  Shift+Enter submitted. The command, also `metacodes terminal-setup
  [--dry-run | --restore] [--terminal …] [--keybindings <file>]`, makes the
  terminal send `ESC CR`, which the key parser now reads as Shift+Enter (the
  sequence Claude Code's VS Code binding sends, so that binding counts too).
  - **`ESC CR` is a newline only when both bytes arrive together**, as a
    terminal writes them for one key. An Esc pressed and then Enter stay two
    keys: vim mode still goes to NORMAL and submits, and reverse search still
    cancels. Bracketed pastes keep their line breaks. Alt+Enter in terminals
    that send `ESC CR` for it (xterm, VTE terminals, Konsole, Alacritty) now
    inserts a newline too.
  - **Apple Terminal:** Shift+Return in the default profile's key map, through
    `defaults export|import` and `plutil`. A profile without a key map of its
    own gets a copy of Terminal's built-in map first, since its own map
    replaces the built-in one whole (measured: a map holding only Shift+Return
    turns off F5, Shift+arrows and Option+arrows). Terminal applies it once it
    is reopened.
  - **VS Code, Cursor, Windsurf, VSCodium and other builds:** a
    `keybindings.json` entry, spliced in with comments and trailing commas
    kept. The file is found through the build's `product.json`. A file that is
    a symbolic link stays one: the file it points to changes. Profiles with
    shortcuts of their own read their own file: they are listed with the
    `--keybindings` command for each, and the footer waits for all of them.
    Key spellings follow VS Code's parser (`shift-enter` counts).
  - An existing Shift+Return mapping or terminal Shift+Enter binding is never
    replaced. Every change is backed up into `<state root>/terminal-setup/`
    and recorded there first; an unreadable record stops the command before
    any change. `--restore` (`/terminal-setup restore`) undoes exactly what is
    recorded, narrowed by `--terminal` or `--keybindings` (naming one with
    nothing recorded fails), and keeps an entry whose file no longer parses.
    iTerm2, WezTerm, Ghostty, kitty and Warp are reported as needing nothing,
    and so, in the TUI, is a terminal that answered the startup
    keyboard-protocol probe; other terminals get the manual setup.
  - The footer says `shift + ⏎ for newline` once the binding works: at once in
    VS Code, after Terminal is reopened in Apple Terminal. See
    [doc/TERMINAL_SETUP.md](doc/TERMINAL_SETUP.md).
- **Release units for aarch64 Linux and Intel macOS** (#307). `release.yml`
  builds `aarch64-linux-gnu` on GitHub's hosted arm64 Linux runner and
  `x86_64-macos` on its Intel macOS runner (`macos-15-intel`), each natively
  and through the same steps as the other units: both Lean kernels, the
  release-configuration suite, `release:verify`, the AgentCore gate, the CLI
  and AgentCore SDK archives and the byte-reproducibility check. Their
  executables are built for the baseline CPU and the oldest system they
  support, glibc 2.31 and macOS 13, not for the runner's CPU and C library:
  the arm64 unit needs no CPU extension (SVE) that Graviton2, Ampere Altra,
  Raspberry Pi 5 or Jetson boards lack. Releases
  from the next one on ship five units. `scripts/install.sh` picks them on
  Linux aarch64 and on Intel Macs; in a Rosetta shell on Apple Silicon it
  picks the native arm64 unit instead. The AgentCore Rust link probe and
  crate tests now know the `aarch64-unknown-linux-gnu` triple. Every POSIX
  release job also installs its own archives the way `curl … install.sh |
  sh` does, from a loopback mirror, so a wrong target pick fails the release.
- **Linux releases ship their debug symbols as a separate asset.**
  - **What the asset is.** Each Linux unit gets
    `metacodes-<version>-<target-id>-debug.tar.gz` beside its archive, holding
    `bin/metacodes.debug`. `release:archive` with `-Drelease-symbols=true`
    links the executable once with DWARF and a build ID, then splits it with
    `objcopy`. The unit ships the stripped half, and the symbols archive the
    other.
  - **How it is checked.** The packager refuses the symbols archive unless the
    unit's executable names that file by build ID and by `.gnu_debuglink`
    (name and CRC-32).
  - **How it is published.** The archive is byte-reproducible, listed in
    `SHA256SUMS`, attached to the release, and downloaded by neither
    `install.sh` nor `metacodes update`.
  - **Effect on the executable.** It grows by 256 bytes (the build-ID note and
    the debug link).
  - **Using it.** `gdb -s metacodes.debug -e bin/metacodes -c core` gives every
    thread's whole stack with function names and source lines, even once the
    executable drops `.eh_frame` (`doc/RELEASE_RUNNER.md`, "Debug symbols").
  - **Code unchanged.** `src/main.zig` turns stack tracing off for every
    ReleaseSmall build, so DWARF no longer links in ~100 KB of unwinding code.
    A stripped build is byte-identical with or without that line.

- **CI reports the footprint red lines** (#303). The Linux and macOS `release`
  legs of `ci.yml` run `scripts/perf_baseline.sh --build` (ReleaseSmall binary
  size, warm `--help` start, idle peak RSS; `doc/PERF_MEMORY_PRINCIPLES.md` §2)
  and write its output to the job summary. The step is report-only: a line
  over its limit marks it failed with a warning, and the leg stays green until
  a few weeks of numbers decide whether it becomes blocking. The script's
  warm-start line measured nothing before: the timed `--help` output landed
  in the captured number. It now times in microseconds and shows 0.1 ms, where
  whole milliseconds had read a 0.6 ms start as 0 ms. An RSS of 0 KB without
  `/usr/bin/time`, or a start it could not time, no longer passes either.
- **The TUI's screen ownership is written down and enforced** (#332, #320).
  [doc/TUI_VIEWPORT_OWNERSHIP.md](doc/TUI_VIEWPORT_OWNERSHIP.md) records who
  may write past the inline region and how: the scrollback only through the
  Renderer, erase/print/redraw in pairs inside one frame, the half-line
  snapshot taken at draw time, ED 0 only, no saved cursor, and the review
  checklist. `zig build test:scrollback` (part of `zig build test`) fails on
  `ESC[1J`/`[2J`/`[3J` outside `tui/ansi.zig`, a wide erase outside
  `resetScreen`, any cursor save/restore, and a direct terminal write from a
  function in `src/repl/` that is not listed with its reason. The unused
  DECSC/DECRC constants left `ansi.zig`, and `src/repl/statusline.zig`, which
  no build imported, is gone with its direct write to stderr.
- A virtual terminal for component tests (`tests/component/vterm.zig`, a Zig
  port of `tests/tty/screen.py` pinned to it by golden vectors, with bounded
  scrollback content) and the first tests that drive the real render region
  through it: emit/erase pairing, half-line continuation, phase hand-off,
  narrow strict-autowrap terminals (#319); and convergence of the streamed
  assistant markdown under token, line, byte, every-single-cut and seeded
  random chunkings, tables cut mid-row or never confirmed, with and without
  the live region redrawn between chunks (#318).
- **Cross-process frontends declare which UI requests they render (#329).**
  A frontend opens its channel with a capability frame
  (`{"v":1,"type":"capabilities","ui_requests":[...],"custom":["<name>@<major>"],"events":[...]}`):
  `POST /capabilities` on `--web` and `serve` (`/s/<id>/capabilities` per
  session), `HostedSession.declareCapabilities` for a `SessionHost` Host. A
  UI request the frame leaves out is no longer announced and failed by a
  round trip: the Host journals `ui_request_unavailable` and the requester
  answers the new `RequestOutcome.unrenderable` at once. The tool fails as
  without a UI — AskUserQuestion with `FrontendCannotRender`
  (`capability_unsupported`), `requestUiCustom` with `CustomUiUnsupported`, a
  permission prompt denied with no terminal fallback — and the tool result
  says the connected frontend cannot render the request and that the user
  never saw it, instead of "failed with NotATty" or "user declined … via
  prompt"; those texts are unchanged where they are true. Custom kinds carry
  their version and match exactly. The reply is a journaled
  `capabilities_accepted` line, or `capabilities_refused` for a frame of
  another schema version or a malformed one, which changes nothing; `GET
  /state` reports the declaration as `frontend_capabilities`. A frontend that
  never declares receives every request as before, and in-process backends
  (TUI, headless, the C ABI) are unchanged. The bundled browser UI declares
  `permission` and `ask_question`, so a custom UI request no longer opens an
  "Unsupported UI request" dialog there. The wire contract, the compatibility
  rules and the policy on which `CoreEvent`/`UiRequest` changes bump
  `SCHEMA_VERSION` are in the new [doc/WIRE_PROTOCOL.md](doc/WIRE_PROTOCOL.md);
  `tests/fixtures/wire/v1` pins the frames and replies.
- **AgentCore Skill sources carry a priority within their scope** (#390). Two
  Host-registered sources of one scope that both defined a Skill name used to
  tie: the name became a `source_conflict`, left `skills[]`, and degraded the
  catalog, so registering `.claude/skills` beside `.codex/skills` could hide a
  `review` Skill both define, and dropping one source also dropped the Skills
  only it had. AgentCore ABI Revision 26 gives every source a signed 32-bit
  priority: `SkillSourceV1.priority` for a Host source, and
  `SkillCatalogQueryV1.default_user_source_priority` /
  `default_workspace_source_priority` for the two `.agents/skills` defaults.
  They take former reserved words; no struct, table, or descriptor changes
  size.
  - A Workspace candidate still beats every User candidate. Within the scope,
    the highest priority wins without an issue and the catalog stays
    `healthy`; a tie at the highest priority is still a `source_conflict`,
    while ties below a unique winner do not matter. Names that only a
    lower-priority source defines stay available.
  - A broken selected candidate reports its issue and never falls back to a
    lower-priority version. Registration order, root paths and source ids
    never choose a winner, and the published Skill, its `source_instance_id`,
    policy grant and execution all name the winner.
  - Every unconfigured source has priority 0, so a zeroed query resolves
    byte-for-byte as Revision 25 did. The Zig and Rust SDKs and the C header
    carry the fields. SDK 0.13.0-dev.
- **An AgentCore Session's provider credential can be replaced in place,
  also during a Run** (#336). An expiring access token used to mean exporting
  a checkpoint, restoring a new Session and destroying the old one, which only
  works while idle: a token that expired while a tool ran or a permission
  request waited ended the Run with `api_error`. AgentCore ABI Revision 25 adds
  `session->update_credential(session, credential, out_error)` (the Session
  table grows from 48 to 56 bytes) and the source-level
  `AgentSession.updateCredential`.
  - Callable while idle and during a Run, from any thread or from the Run's own
    callbacks; never `BUSY`. Concurrent updates are linearized. A request reads
    the credential when it is sent (once it holds its connection slot), so
    every request sent after an update returns carries it: the Run's later
    turns, retries of a request already under way, compaction summaries, Skill
    Runs and forked Skills, a tool's own per-call provider (`WebSearch`)
    including one built before the update, and a request that was still
    waiting for a connection slot. A request already sent and a stream being
    read are left alone.
  - Only the credential changes: provider, authentication scheme, `base_url`
    and model stay. An empty credential, a byte outside printable ASCII, more
    than `MAX_CREDENTIAL_BYTES_V1` (16 KiB), or an allocation failure is
    refused and keeps the previous credential; a poisoned Session refuses
    with `INVALID_STATE`. Diagnostics name the rule, never the bytes.
  - The replaced credential is erased before the call returns and the last one
    when the Session is destroyed. No credential reaches checkpoints,
    `describe`, events or diagnostics; restore still uses the credential in
    its configuration.
  - Every Session-owned provider now reads one Session-owned credential at each
    request instead of borrowing the Session's key bytes. The Python
    (`Session.update_credential`) and Node (`Session.updateCredential`)
    packages, the Zig and Rust SDKs, and both source-free consumers carry the
    slot. SDK 0.12.0-dev.

### Changed

- **Smaller Linux footprint: idle RSS back under its red line, binary
  433 KB smaller.** On x86_64 Linux, the ReleaseSmall binary was 6.60 MB
  (red line 6 MiB) and `metacodes --help` peaked at 3120 KB RSS (red line
  3 MB; `doc/PERF_MEMORY_PRINCIPLES.md` §2). Nothing a user sees changes;
  measured in WSL on x86_64:
  - **Signal stack.** The release binary no longer reserves std's 256 KiB
    alternate signal stack. It is thread-local, and glibc zeroes it for
    every thread, the main one included. Only std's segfault handler uses
    it, and the release build does not install that handler, so sessions
    also save 256 KiB per thread.
  - **`--help` first.** `metacodes --help` (or `-h`) as the first argument
    prints before the rest of startup runs, with byte-identical output.
  - **No zero-filled constants.** The provider control plane's event ring is
    no longer copied out of a 138 KiB read-only constant.
  - **Run-end records out of line.** The agent loop's nine run-end records
    run as functions instead of being copied into every exit of the loop
    (−277 KB).

  Result: 6.19 MB binary and 2564 KB RSS for the native build; 6.16 MB and
  2920 KB for the glibc 2.31 baseline-CPU build. RSS is now under its red
  line, but the binary is still about 195 KB over 6 MiB. The macOS binary
  is 283 KB smaller. §3g records the Zig 0.16 patterns behind the waste:
  aggregates copied from zero-filled constants, and `defer` bodies copied
  into every exit.
- **The TUI's turn phase now owns every widget it opens (#330).** The agent
  switcher, `?` help, the Ctrl+X prefix, the slash/`@` menu highlight, the
  paste hint, the double-press windows, the model picker, the input box
  projection, the spinner and the tool cards used to live side by side in one
  session-long `UiState`, kept from leaking into the next prompt or reply by a
  reset list at every boundary (#298). They now live in the payload of the
  phase they belong to (`idle`/`input`/`generating`), which a single typed
  `phase_change` event replaces wholesale, so nothing a reply or a read opened
  can outlive it and a new widget is torn down without being listed anywhere.
  A top-level field without a declared reason to outlive phases fails the
  build, and a debug build panics on a phase that opens before the previous
  one closed. The picker still crosses a boundary, but only through its
  explicit `pending_overlay` hand-off (#220). No visible behaviour changes.
- **Busy replies write far fewer terminal frames (#328).** Each streamed line,
  spinner tick, tool progress update and key typed during a reply used to be
  its own erase-and-redraw frame of the fixed region, so a model writing many
  short lines made the terminal parse a full region redraw per line. Redraws
  now go through a 16 ms merge window: a request with nothing painted in the
  last window still paints at once, and requests inside the window share one
  frame at its end that shows the state at that moment. Streamed text is
  queued in order and never dropped. Submitting, a tool finishing, an
  interrupt and phase or dialog boundaries still paint immediately, and a
  WebSearch result line is always painted before its card goes. The end of
  each provider turn is now one synchronized frame instead of three writes,
  and a resize while the region was hidden no longer printed a blank line.
  If metacodes panics mid-reply, the lines still waiting for the window are
  written before the panic message, and the live region no longer draws
  over the stack trace.

- **The Linux release binary no longer carries unwind tables (`.eh_frame`),
  saving 300 KB.** The program never read them. A panic in the stripped
  binary prints its message without a stack trace either way, and frame
  pointers are kept. What changes is post-mortem debugging with outside
  tools:
  - **With the release's debug-symbol asset** (`metacodes.debug`, above):
    gdb unwinds every thread's whole stack, with function names and source
    lines, from the `.debug_frame` the asset carries.
  - **Without it:** gdb can no longer unwind a core past the first metacodes
    frame, and CFI-based unwinders (`perf --call-graph=dwarf`,
    systemd-coredump) degrade the same way. `perf --call-graph=fp` still
    works.

  macOS and Windows binaries are unchanged
  (`doc/PERF_MEMORY_PRINCIPLES.md` §3f).

- **Shift+Enter inserts a newline in any terminal that says it can, not only
  in the ones metacodes knows by name (#327).** The Kitty keyboard protocol
  used to be turned on only when `TERM_PROGRAM`/`TERM` named iTerm2, WezTerm,
  Ghostty, Warp, kitty or tmux. Every other terminal, including any terminal
  reached over SSH (which forwards `TERM` but not `TERM_PROGRAM`), fell back
  to bare Enter, so Shift+Enter submitted and the footer said `\ + ⏎ for
  newline`. At startup the interactive REPL now asks a terminal it cannot
  place the Kitty flags question (`CSI ? u`) followed by a DA1 request, in
  the same write as the background-colour query: every terminal answers DA1
  and answers in order, so DA1 arriving without a flags answer is a definite
  no, and the round ends as soon as it does. The 120 ms deadline is only a
  fallback (no answer: the protocol stays off). The named terminals and tmux
  are still turned on without asking. Apple Terminal and the xterm.js hosts
  (VS Code, Hyper) are now a deny-list that is neither asked nor turned on
  (Claude Code #23350); a terminal whose own `TERM` names it (kitty,
  Ghostty) is still turned on when it was started from one of them and
  inherited their `TERM_PROGRAM`. A dumb terminal, GNU screen, zellij and
  `METACODES_NO_PROBE` are not asked either. Windows consoles are not asked:
  on Windows Terminal 1.24 the console host answers DA1 itself (in about
  0.1 ms) and never the flags question. With the protocol on, Alt+B and
  Alt+F arrive as `CSI 98;3u` / `CSI 102;3u`; the key parser now reads them
  as word movement (it dropped them, in kitty, WezTerm and Ghostty too).
- **Keys typed while metacodes starts are no longer lost to its terminal
  query.** The background-colour probe discarded every byte it read that was
  not its answer, and switched modes with `TCSAFLUSH`, which discards typed
  input outright. The startup probe now keeps the input already received and
  hands every byte that is not an answer back to the REPL's input, in order,
  ahead of what the terminal sends next. Answers already queued before the
  query (left unread by a program that ran before) are read first and
  dropped, so another program's DA1 is not taken for this round's.
- **A terminal's answer that arrives after the startup probe gave up (a
  link slower than 120 ms) is no longer echoed, taken for a key, or typed
  into the prompt.** Until the REPL takes the terminal it stays quiet (no
  echo; Ctrl+C still works; restored at exit if startup fails), and what
  arrives is read through the probe's answer scanner: answers are dropped,
  keys are kept. A late answer used to be printed above the banner
  (`^[[?62;22c`) or end the startup animation as if it were the key that
  skips it. An answer the deadline cut in half is dropped rather than handed
  to the prompt, where its missing tail took the user's next key; one still
  open when queued input was thrown away since (a `TCSAFLUSH` mode switch
  that found input waiting) is given up, and after a read wait without its
  tail, each byte that follows is taken for its tail only while it fits
  (digits up to `c`/`u`, a colour up to BEL) and none restarts the wait;
  when one does not fit, the answer is given up and the bytes it took since
  are typed, so text typed key by key is not read as its tail (`fix the
  bug` used to leave only `bug`). Reading what queued up stops where
  stdin's replay is full instead of overrunning it (a 4 KiB burst typed
  during such a startup crashed a Debug or ReleaseSafe build). The key
  parser also consumes a whole private-marker CSI (`ESC [ ? … c`,
  `ESC [ ? … u`), any CSI with more parameters than it decodes (xterm's
  `ESC [ 27 ; 2 ; 13 ~`), and an OSC answer (`ESC ] 11 ; … BEL`), reporting
  one unknown key for each; a sequence whose rest has not come within one
  read wait is dropped instead of swallowing the next key; and rxvt's
  `$`-terminated Shift keys (`ESC [ 3 $`) stay one key.
- **Shift+Enter inserts a newline in Windows Terminal and the classic
  Windows console (#386).** A Windows console sends Shift+Enter as the same
  `\r` as Enter, so it submitted the prompt and the footer said `\ + ⏎ for
  newline`. When stdin and stdout are both console handles, the REPL now
  turns on win32-input-mode (`CSI ? 9001 h`) as it enters raw mode and turns
  it off as it restores the terminal; redirected streams and Linux binaries
  under WSL leave it off. With it on, the console sends each key event as a
  record `CSI Vk;Sc;Uc;Kd;Cs;Rc _`. The console input is read in one place
  (`platform/terminal.zig` `readInput`), and that is where the records are
  turned back into the VT bytes the same keys send without the mode, for
  every reader: the prompt, the permission and question dialogs, the pager
  and vim's normal mode, which read single bytes past the prompt's key parser
  (the dialogs read the console with the C runtime's `read` before and now go
  through `readInput` too; a guard test keeps any other read away from the
  terminal). Key-up records give nothing, and a wait for input is not woken
  by them, so an Esc's own key-up does not restart the wait that tells Esc
  from an escape sequence. A record's character is typed `Rc` times, at most
  256 (a UTF-16 surrogate pair split over two records is one character), and
  a key that types nothing is never repeated. Arrows, function keys, Esc, Alt
  and Ctrl chords and bracketed-paste markers decode to their VT bytes
  (checked byte for byte against Windows Terminal 1.24 and conhost on Windows
  11 26300). Shift+Enter becomes Kitty's `CSI 13;2u`, a newline. The footer
  says `shift + ⏎ for newline` once a record has typed text: Windows Terminal
  and conhost send records for every key, while a terminal that sends only VT
  bytes through ConPTY (Alacritty) gets records for its lone CR, ESC or
  Ctrl+letter but never for text, and its Shift+Enter still submits.
  Ctrl+Enter still submits: the pseudo console sends a line break written to
  it as an Enter with Ctrl held, the same record. Bytes a terminal writes in
  one go, such as the `ESC CR` of a Shift+Enter key binding in VS Code
  (`/terminal-setup`), reach the key parser as those bytes, not as records,
  and stay a newline; an Esc pressed on the keyboard is a record and never
  counts as that binding's ESC, however soon Enter follows it. AltGr and dead
  keys were not measured.


### Fixed

- **An answer still cut at the output-token limit after the last
  continuation ends the Run as incomplete, even when it has text (#394).**
  After the initial request and its three continuations, a last turn that
  still ended on the wire's max-token report (Anthropic `max_tokens`, Chat
  Completions `length`, Responses `response.incomplete` with
  `max_output_tokens`, Gemini `MAX_TOKENS`) only reached
  `max_tokens_exhausted` when it streamed no text. With visible text it was
  closed as the final answer. Such a turn now ends in `max_tokens_exhausted`
  either way, and its text is still delivered, marked incomplete:
  - Headless `--json` reports `stop_reason=max_tokens_exhausted` and
    `text_kind=partial` (the whole continued text) instead of `end_turn` and
    `final`, and **the process exits 1 instead of 0**: a script that reads
    exit 0 as success now sees such a Run as failed. The `--stream-json`
    timeline ends `continued → … → partial` instead of `… → final`.
  - The REPL says the reply was cut off instead of ending silently.
  - A `TaskBatch` item keeps its `final_text`, marked `"incomplete":true`
    with its `stop_reason`, and counts toward `failed` instead of
    `completed`. Provider errors and aborts are still an `error` with no text.
  - AgentCore ABI v1 reports the stop as `api_error` with a `failed`
    RunState, and the Session takes the next Run. Before,
    `max_tokens_exhausted` (then reached only without text) returned
    `INTERNAL_ERROR` and poisoned the Session. No wire code is added. In the
    Python and Node SDKs, `text` holds only a final answer and is empty for
    this stop; the cut text is in `segments`, closed as `partial`.
  - Swarm teammates report `needs_continuation` instead of `available`.
  - **A sealed Skill run whose last turn is still cut now fails**: its Step
    is `failed` with `skill_error` and a message naming the cut, where it
    returned the truncated text as `final` before. A `failed` Step has no
    `text`, so the truncated answer stays on the gateway. Carrying it would
    need a Sealed Skill protocol revision with the disclosure screen, which
    is left for later.

  A complete tool call on that turn still runs, and a continuation that ends
  normally is still one final answer. Tested on all four wires against a
  loopback mock.
- **A Skill whose `name` or `description` is empty or only whitespace is
  read as if the field were absent, and `/skills` reports it (#395).** The
  Agent Skills specification requires both to be non-empty. A blank `name`
  already fell back to the directory name, but silently, and a whitespace-only
  one was kept as the display name. A blank `description` got no fallback at
  all, so `name: ""` with `description: ""` was listed to the model as the
  bare name (`- **demo**`). Both now get the fallback an absent field gets:
  the directory name, and the first body line (Claude Code reads a blank
  `description` the same way; Codex reads both as absent). The Skill still
  loads. The blank field is a typed warning in the definition
  (`definition.Warning`), and `/skills` names it: "SKILL.md has a blank
  `description`" under "No description", and a new "Blank name" list. The
  startup banner and `/doctor` count each such Skill once. With no body line
  either, the Skill is listed with no description, as when `description` is
  absent. AgentCore's canonical catalog has no body fallback: there a blank
  `description` is now empty, as an absent one is, instead of the blank text.
- **The first prompt no longer waits up to 2 s for the startup suggestion.**
  The `suggestion: explain or improve <file>` line comes from `git log -1
  --name-only`, which ran before the first prompt with a 2 s limit. On macOS
  that git is Xcode's `/usr/bin/git` shim (the capture runs it with an empty
  environment), which takes 1.1-2.5 s while its xcrun cache is cold. git now
  starts on a thread of its own as the REPL starts, and the first prompt
  waits for it at most 250 ms. A git still running then is left to finish,
  so a cold shim writes its cache and the next start has the suggestion
  (killed early, it would stay cold at every start); it is stopped when the
  REPL ends. On macOS 26, 15 and 15 Intel runners with the cache cleared, the
  first prompt came after 0.26-0.43 s instead of 1.2-2.3 s, and the start
  after it showed the suggestion after 28-55 ms. Linux is unchanged (5-8 ms).
- **A multi-line paste in Windows Terminal or the classic Windows console
  stays in the prompt instead of submitting every line but the last
  (#386).** On Windows the REPL never turned on bracketed paste: `TERM` is
  usually unset there, so the terminal counted as dumb, and with `TERM` set
  the sequence went to stdin, which a console does not show. Windows Terminal
  first warned about the multi-line paste, then both hosts sent each line
  break as Enter. On a console the REPL now writes `CSI ? 2004 h` to stdout
  with win32-input-mode and turns both off again on restore: Windows Terminal
  wraps the paste in `ESC[200~ … ESC[201~` and no longer warns, and classic
  conhost sends the markers as key records with the text. Measured in both
  with a pasted Chinese and ASCII text of 3 and of 80 lines.
- **The editor a question's note opens with Ctrl+G gets a plain terminal
  (#386).** The question dialog handed the terminal to `$EDITOR` in cooked
  mode but left the escape modes on: bracketed paste and, where the terminal
  speaks it, the Kitty keyboard protocol, so the editor read paste markers
  and Kitty key codes. It now turns them off for the editor and on again
  after it, as the prompt's own Ctrl+G does, together with a Windows
  console's win32-input-mode; the console it hands over has no VT input
  either.

- **Release executables run beyond machines like the build runner.**
  `release.yml` built the CLI executable without `-Dtarget`, so zig targeted
  the runner: its CPU, glibc and macOS. Every published release from 0.4.0 to
  0.8.0 is affected:
  - The x86_64 Linux executable needs GLIBC_2.36 and an AVX2 CPU. On Ubuntu
    22.04 the 0.8.0 one exits with "version `GLIBC_2.36' not found".
  - The Windows executable needs AVX2, and AVX-512 in 0.4.0, 0.6.0 and 0.8.0.
  - The aarch64 macOS executable declares macOS 26.6.2 as its minimum.

  Each unit is now built for an explicit target (`cli_target`): the baseline
  CPU and the oldest system it supports. Those targets are
  `x86_64-linux-gnu.2.31`, `aarch64-macos.13.0` and `x86_64-windows-gnu`.
  The new `scripts/check_binary_baseline.py` step fails a release whose
  executable needs more. It disassembles the executable (no AVX, AVX2 or
  AVX-512 on x86_64; no SVE or Armv8.6 matrix instructions on aarch64) and
  reads the GLIBC symbol versions and the Mach-O minimum macOS. The Lean
  kernels were never affected: they are built for the baseline CPU and need
  GLIBC_2.14.
- **Ctrl+L during a reply clears the screen through the renderer** (#320).
  The keyboard watcher sent `ESC[2J` straight to the terminal, outside the
  render lock and between two frames, while the agent loop could be printing,
  and kept the half-line continuation whose text the clear had just removed.
  Ctrl+L, `/clear` and `/resume` now share `RenderRegion.resetScreen`: it
  erases the region, clears the screen and, during a reply, draws the region
  again on the top row, in one synchronized frame, and drops the
  continuation. The scrollback is never wiped (no `ESC[3J`).
- **Code blocks in a streamed reply are highlighted for their fence's
  language.** The live markdown renderer kept the language as a slice of the
  line buffer the reply streams through; by the block's first code line that
  buffer had been shifted to the next line (and sometimes reallocated), so
  the slice read other bytes and blocks were highlighted with the generic
  keyword set (a Python `lambda` or `None` stayed plain). The renderer now
  keeps its own copy of the language name.
- **The footer no longer wraps on a narrow terminal.** The mode and key-hint
  line (`⏵⏵ accept edits on (shift+tab to cycle) · esc to interrupt`) was
  never cut to the terminal width. On a terminal narrower than it, the
  terminal wrapped it onto rows the input box does not count, and with the
  box at the bottom of the screen every redraw pushed the spinner, border
  and prompt rows into the scrollback. It is now cut with an ellipsis, like
  the MCP notice on the same line.
- **Python package: a host tool can run a child Session on Windows.** A Run
  executed on the thread that called `Session.run`; on Windows the main
  thread of python.exe reserves 2 MB, and a Run that a tool started from
  inside another Run overflowed it. ctypes reported the overflow as
  `OSError: exception: stack overflow`, the child's Run never finished, and
  closing the child failed with `BUSY`. Every Run now executes on its own
  thread with an 8 MiB stack, the size the Node addon gives its Run threads,
  so nesting no longer depends on the caller's stack. The thread is not a
  daemon, and an interrupt (Ctrl+C) while `run()` waits for it aborts the Run
  and waits for it to end before it propagates; a second interrupt stops the
  wait and leaves the Session busy until the Run ends, so `abort()` and
  `close()` still reach it. A Run's thread starts inside the callbacks of the
  thread that started it, so closing a Session from a callback of a child Run
  that the Session's own tool started is still refused with RuntimeError, as
  when the child ran on the tool's thread, instead of aborting the Session's
  Run and waiting for a return that cannot come. The suite's
  permission-target test compares paths as paths, since AgentCore names
  Windows paths with forward slashes.
- **A provider credential with a byte a request header cannot carry no longer
  ends the process.** Session create and restore accepted any UTF-8 as
  `api_key`, and the CLI sent whatever bytes its flag, environment, key file
  or token response held; a credential with CR LF reached the HTTP client,
  whose header assertion ended the process at the first request (a panic in
  ReleaseSafe). Create and restore now apply the rule `update_credential`
  applies (1 to 16 KiB of printable ASCII): AgentCore returns
  `INVALID_ARGUMENT` (`RESOURCE_LIMIT` when too long) with a diagnostic that
  names the rule and never the bytes, and `AgentSession` creation fails with
  `error.InvalidCredentialByte`. A fixed (CLI) credential is checked before
  every request and fails that request instead of sending it.
- **A draft typed during a reply survives a permission or question dialog.**
  The keyboard watcher owned the draft, and a dialog stops the watcher and
  starts a new one when it closes. So the input box went on showing a buffer
  that had already been freed, and the next key or Enter dropped what had been
  typed. The draft now belongs to the reply: after the dialog the box still
  shows it, the cursor is where it was, and Enter queues all of it.
- **The model picker no longer races the reply's frames.** A picker opened
  during a reply is written by the keyboard thread while the reply's text
  frames are drawn on another; a catalog refresh with the picker open (a
  sign-in landing, or a commit that met a configuration change) rebuilt the
  offer list under a frame that was still indexing it, which a safe build
  reports as an out-of-bounds panic. Every change to the picker now holds the
  render lock for the change alone; committing a route, signing in and
  listing the catalog run outside it.

- **The Linux binary is back under 6 MiB** (246 KB more off, no change in
  behavior). Functions that return a large result (the provider config
  document, an HTTP request result, a tool result, a tool-dispatch
  outcome) no longer return literal errors directly. Each such return used
  to copy a read-only constant the size of the result, one per error name.
  - **Large results:** the work is now done in a function that fills the
    result through a pointer, wrapped by the original signature.
  - **Up-front checks:** they return no result, and the caller uses `try`.

  The agent loop's per-turn buffers are also freed out of line.

  The native build is now 6098 KB and the glibc 2.31 baseline build
  6078 KB, 0.7% and 1.1% under the red line; idle RSS is 2272 and 2620 KB
  (`doc/PERF_MEMORY_PRINCIPLES.md` §1, §3g).

- **Everything typed while metacodes starts reaches the first prompt, in
  order.** The key that skipped the startup animation was consumed by it (on
  Windows the skip flushed the console's whole input queue, so `abc` typed at
  startup became `bc` or nothing), and on macOS and Linux the input box's
  first raw-mode entry (`TCSAFLUSH`) dropped whatever was typed after the
  animation while startup still ran (connecting MCP servers, fetching the
  model list). The animation still ends on the first key, but leaves the key
  for the prompt (only a key that types nothing, a bare modifier on Windows,
  is dropped: a console read would wait behind it for the next key that
  types); it enters and leaves raw mode without discarding input; and
  the process's first raw-mode entry keeps what the terminal has received.
  Later entries still drop keys typed between two prompts, as before.
- **A multi-line paste made before the first prompt lands in it as one paste
  and is not submitted line by line.** Bracketed paste is turned on with the
  first prompt, so a paste right after starting arrived as typed keys and
  every newline was an Enter: the first line went to the model on its own,
  and the rest was dropped or queued as the next turn. Everything typed
  before the first prompt, of any length, now goes into it as one paste:
  newlines stay text, Backspace still deletes, other keys are left out, a
  large paste becomes the usual placeholder, and nothing is sent until Enter.
  The newlines it starts or ends with (the Enter that skipped the animation,
  the one after the last line) are left out, and input that is only blanks
  leaves the prompt empty. Startup input is read until the terminal has been
  quiet for two of its round trips, as the startup probe measured them (50
  to 500 ms), so a paste a slow link delivers in parts is still one paste.

### Security

- **An AgentCore MCP Session grant no longer follows a server to a new
  endpoint** (#389). A Session grant (`allow_session`, `deny_session`) was
  bound to the server binding, the MCP Tool name and its schema. When
  `apply_configuration` kept those three but pointed the server binding at
  another endpoint under a new `configuration_fingerprint`, an existing
  Session sent the same call to the new endpoint without asking, and a
  checkpoint restored the grant the same way. The MCP `permission_binding`
  now also binds the server's `configuration_fingerprint`, the Host's name
  for the connection. After such a change the Tool stays selected and its
  next call asks again (or falls back to the permission mode); a
  `deny_session` answer does not carry over either, and Host allow and deny
  rules still decide by name. The old grant is dropped where the change is
  first seen: by the next Run and by `update_selection`, counted in Session
  `describe` as `restore.invalidated_mcp_bindings`; by restore, as an
  invalidated `permission` rule with an issue. Either way health turns
  `degraded`. A change that keeps the fingerprint (namespace, client info,
  timeout, negotiation policy, protocol limits) keeps the grants. Hosts must
  change the fingerprint whenever the endpoint, the transport target or the
  authenticated principal changes, and keep it when only a credential for
  the same principal rotates. MCP Session grants in checkpoints exported
  before this change carry the old binding, so restore invalidates them
  (`degraded`) and their next call asks.
  See [MCP Runtime catalog and Session
  view](doc/AGENTCORE_BINARY_ABI.md#mcp-runtime-catalog-and-session-view).


## 0.8.1 — 2026-10-28

### Fixed

- **A resumed session no longer fails with `error: InvalidRecord` on the next
  turn.** When a provider stream died mid-turn, the agent loop re-issued the
  same request within the turn and restarted the provider retry budget at
  physical attempt 1. The attempt id is derived from the request, the logical
  turn and the attempt number, so the re-issue collided with the attempt it
  replaced, writing two `provider_attempt` records with the same id. The
  writer never re-reads its own journal, so the duplicate rode along for the
  rest of the session; only a fresh process validating the journal on the
  first new Run (a `/resume` followed by a message) rejected it. The journal
  reader now treats a balanced started → finished → started → finished as the
  legitimate re-issue it is (a still-open duplicate id is still refused), so
  sessions already carrying one open again; and the writer folds every
  same-turn re-issue into the recorded generation, so a new re-issue always
  gets a distinct id.
- **A session whose turn was killed can be resumed.** A turn's lease on
  `<session>/tool-observations.lock` was a file created with `O_EXCL` and
  deleted at the end of the turn, so a process killed mid-turn (a closed
  terminal, `kill`, an OOM kill) left it behind, and every later turn in that
  session failed with `error: JournalBusy`, which also exited the REPL. The
  lease is now held under a lock the kernel drops when its owner dies (`flock`
  on macOS and Linux, `LockFileEx` on Windows) and names its owner's pid, its
  Run and when it started. A turn that finds the lease held by a live process
  is refused with who holds it and since when ("Another metacodes process (pid
  4242) has been running a turn in this session since 21:19 …"), and the REPL
  stays up. A turn that finds the previous Run's process gone closes that Run
  with a `run_abandoned` record (its run id, its open tool calls and provider
  attempts, and why its owner is known to be dead), says so ("… ended when its
  process exited while Bash was running … check its effects before relying on
  them"), and starts. Nothing is replayed, and an abandoned Run is never rule
  evidence. The REPL, `-p`, the web UI and the daemon recover this way;
  AgentCore and `AgentSession` keep failing closed (`UnfinishedRun`). An empty marker left by an older binary counts as
  abandoned only when no process has it open and it is not one that binary
  kept after its last Run finished. When a Run is recovered, a record
  half-written as its process died is cut, and the cut is recorded in the next
  `run_started`. 0.8.0 and earlier cannot open a session holding these
  records.
- **SIGTERM and SIGHUP end a turn cleanly.** The REPL used the default action,
  so closing the terminal or `kill` killed it mid-turn without closing the
  Run. Both signals now interrupt the turn as Ctrl+C does, let it close its
  journal and release its lease, and exit; a turn that has not finished 45 s
  later is cut off. A second signal changes nothing, because closing a
  terminal sends SIGHUP twice milliseconds apart. A SIGHUP ignored on entry
  (`nohup`) stays ignored.
- **WebFetch decodes compressed pages, or says it cannot** (#358). curl ran
  without `--compressed`, so a server that compressed its response anyway
  (gzip, deflate, Brotli) handed the HTML extractor the compressed bytes, and
  WebFetch returned the garbage as a successful page, in the host's
  `tool_result` and in the next provider request. WebFetch now asks for the
  encodings the system curl decodes and decodes the body before extracting
  text. An encoding that curl cannot decode (Brotli or zstd on a curl built
  without them, such as the one Windows ships, or an unknown token) and a
  corrupt compressed body fail the call with curl's reason instead; that
  failure does not count toward the offline breaker.

## 0.8.0 — 2026-10-26

### Added

- **Guided API-key login for the GLM Coding Plan.** Zhipu offers no
  third-party sign-in, so a Z.AI key could only come from `ZAI_API_KEY`, and
  `login --provider zai-coding-plan` refused. Now `metacodes login --provider
  zai-coding-plan`, `/login` and a `/model` pick without a key list the four
  Coding Plan key pages (China / Global, personal / team, the one for the
  chosen channel's region first), open the chosen page, take the pasted key
  without showing it, check it with the plan's model list (a GET that is not
  billed) and store it in `<state root>/keys/zai-coding-plan.json` (0600,
  never `config.json`). A refused key, or one that could not be checked, is
  not stored. The stored key is used only for Z.AI, after `ZAI_API_KEY` and
  its aliases; `metacodes logout --provider zai-coding-plan` removes it.
  Scripted: `--api-key-stdin`, `--key-page <id>`, `--no-check`. The note on
  every key page says why a standard API key is the wrong one: since
  2026-10-16 it bills the account balance even on the Coding Plan endpoints.
- **`metacodes update`** brings an install up to date from where it came
  from (doc/UPDATE_DESIGN.md). A release install moves to the latest
  published release, or `--version X.Y.Z`. The archive is downloaded, checked
  against the release's SHA256SUMS, unpacked with symlinks, `..` and other
  escapes refused, and verified against its own manifest. The new release's
  own `install --upgrade` then installs it. A development install is rebuilt
  by its checkout's `scripts/install.sh --dev` (`--pull` fast-forwards the
  checkout first).
  - An install never moves backwards without `--allow-downgrade`. An update
    of an intact install to the version it has downloads nothing, and a
    damaged or half-finished install is repaired.
  - The update is refused while sessions run from the install
    (`--ignore-running` overrides that, except on Windows), because an old
    session's next kernel check would fail closed. The install's TinyKG
    service is stopped, and repinned when the TinyKG binaries change.
  - `--check` reports without changing anything (exit 3 when there is
    something to do), and `--json` prints the result.
  - Downloads go through curl, as `install.sh`'s do, so proxies, `NO_PROXY`
    and SOCKS behave the same for both. A transfer stops after 60 s without
    a byte, and only a loopback mirror may use plain http. On Windows the
    running executable is renamed aside so it can be replaced.
- **Install records say where an install updates from.** `metacodes install`
  takes `--release-base <url>` (a releases mirror) or `--checkout <dir>` (the
  checkout that built a development unit) and records it in
  `etc/metacodes/install.json` as `update_source`. Without either option, a
  reinstall keeps what the record had. `scripts/install.sh` passes the base
  it downloaded from and, with `--dev`, its checkout. `scripts/install.ps1`
  takes `-ReleaseBase`. Both pass these options only to a release whose
  installer knows them.

### Changed

- **The built-in OpenAI, Gemini and GLM Coding Plan models are the current
  frontier ones, with their documented limits and reasoning levels.**
  - OpenAI: `gpt-6-astra`, `gpt-6.1-sol` and `gpt-6-luna` (1,050,000-token
    window, 922,000 input, 128,000 output), offered on the Responses wire only
    because tool calls need it on these models; reasoning effort low / medium /
    high / xhigh / max. gpt-4o, gpt-4o-mini and o3 are deprecated and o3-mini
    was shut down on 2026-10-23.
  - Gemini: `gemini-4-argon` and `gemini-3.8-flash` (1,048,576-token window,
    65,536 output); thinking level low / medium / high.
  - GLM Coding Plan: `glm-5.3` and `glm-5.3-flash` (1M window, 128K output);
    reasoning effort low / high / max. GLM-4.6 / 4.5 / 4.5-Air are gone from
    the list; `glm-4.5-air` had no limits at all, so picking it failed
    admission.

  `--model` still sends any model id to these providers.

- **Zig embedders of `metacodes-core` (experimental source API):**
  - `kg_client.KgClient.Autostart.start` now receives a
    `KgClient.StartReason` (`not_running`, `key_refused`, `stale_pin`).
  - `kg_transport.Error` gains `BuildMismatch`, which the transport returns
    where it used to return `IncompatibleDaemon` for a service that matched
    in everything but its build id.

### Fixed

- **A request carrying a key no longer follows a redirect.** Zig's HTTP
  client re-sends its extra headers on every redirect hop, to whatever host
  the redirect names, and turns a POST answered 301/302/303 into a GET; the
  headers it would strip across domains it never sends at all. The Messages
  client, the `/v1/models` probe, the account key list, authenticated catalog
  fetches, the KG and sealed-skill transports and MCP over HTTP therefore took
  their key (`x-api-key`, `Authorization`, configured MCP headers) to any host
  a redirect named, and the OAuth token and device grants took a POST that
  became a GET elsewhere and read its answer as a token response. Every such
  request now ends at the redirect. The model clients report it with its
  target (`端点重定向: HTTP 302 → <url>`, so the fix — that URL as the
  endpoint — is in the message); the OpenAI and Gemini clients used to fail
  with `HttpRedirectLocationOversize`; MCP reports `McpRedirected` instead of
  "the server answered with an HTTP 5xx error". A public catalog still
  follows redirects.
- **Sign-in pages open on macOS.** With no `BROWSER` set the opener was
  `xdg-open`, which macOS does not have; the launch failed after the fork, so
  no OAuth or device-code page ever opened there and nothing said so. macOS
  now uses `open`.
- **Every model of a long list can be picked.** The `/model` picker built at
  most 256 rows per step, so a gateway listing 300 models showed `[1/256]` and
  the last 44 could be reached only by typing their names; the `/models` menu
  let the selection reach only the first 8 API keys or models it listed. Both
  lists now hold every entry, scroll with the selection, and take PgUp/PgDn
  and Home/End (↑ from the first row still wraps to the last); a list longer
  than its window says `[n/m] · PgUp/PgDn page · Home/End` under it.
- **A paginated `/v1/models` is read to its end.** The list is Anthropic-shaped
  (`has_more`, `last_id`), and the session's probe, its background refresh and
  the Metask session login's catalog fetch kept only the first page. They now
  follow `after_id` until the gateway says there is no more (at most 50 pages
  of 1000), so every model a key may use reaches `/model` and `/models`. A
  single-page list is read exactly as before.
- **`--provider zai-coding-plan --model <listed model>` starts.** Z.AI declares
  every model on four channels, so naming one stopped the start with "model
  matches several routes" while an unlisted model or a bare `--provider`
  already took the declared default channel. A listed model now takes the
  default channel too; only a choice the default channel cannot settle (two
  wires there) is still reported. A `--base-url` without `--channel` no longer
  fails for every Z.AI URL: it goes to the channel whose routes accept it (the
  default channel when it does), instead of being checked against all four.
- **Reasoning effort reaches each route in its own words.** `max` is a level
  of its own above `xhigh` (OpenAI's GPT-6 models take both; `--effort max`
  and stored `max` values used to become `xhigh`); routes whose top level is
  called max (GLM, Kimi, DeepSeek, Anthropic) send both as `max`. The OpenAI
  Responses wire sends `xhigh` and `max` by name instead of capping them at
  `high`. GLM-5.3 and later always get `thinking: enabled` with a low / high /
  max effort: `none` used to send `thinking: disabled`, which GLM-5.3 refuses.
  On the Anthropic wire (Z.AI's default channel, the Metask gateway) GLM-5.3
  gets the same low / high / max words instead of Anthropic's `medium`.
  Gemini 4 (`gemini-4-argon`) is treated as the Gemini 3 family it extends:
  its thinking cannot be switched off.
- **A reasoning level chosen in `/model` is the one the next request
  carries.** The picker's options step had no key that applied a route (Enter
  cycled the value), so a route declaring a control could not be picked at
  all, and a level committed through the kernel never reached the client.
  ←/→ now change a value, Enter applies the route with the values shown, and
  the chosen `reasoning_effort` becomes the session's level. A route that
  offers the level the session already runs with starts with it selected; a
  commit that carries no level keeps the session's, as `/model use` does.
- **`/model use <name>` means the provider the session is on.** A name several
  providers list (glm-5.3-flash is on the Metask gateway and on Z.AI's four
  channels) was reported as ambiguous; it now switches to the current
  provider's route when that provider has exactly one, then the current
  channel's. A name only other providers list on several routes is still
  reported with its offer ids.
- **Gemini 3 and later can call tools past the first step of a turn.** These
  models reject a request whose current turn returns a model function call
  without the `thoughtSignature` it arrived with (400), and the client dropped
  every signature, so the second request of any turn that used a tool failed.
  Signatures are now kept by the call ids the client mints and sent back on
  the part they came on; a step's first call the client never received
  (history from another model, a resumed session) carries the documented
  placeholder. An unchosen thinking level is no longer sent as `low` to
  Gemini 3 and later: their default (medium on Gemini 4 Argon and 3.8 Flash)
  applies.
- **A TinyKG service on new binaries no longer leaves every session
  degraded.** The service's build id is a hash of the TinyKG binaries.
  Previously, after an update, a rerun of `install.sh` or a hand install
  changed them, `daemon.json` kept pinning the old id. Every session was then
  refused (`pin_mismatch`), fell back to the `tasks.json` mirror, and stayed
  there until someone ran `metacodes kg install`. Now the transport reports
  this case as its own error (`BuildMismatch`), and autostart repins this
  install's own service to the installed binaries, keeping the key, the port
  and the store. It does so before it starts a service, and when a session
  meets the stale pin. A session that degraded before the repin recovers on
  its next probe. A `METACODES_KG_CONFIG` file is never rewritten
  (doc/TINYKG_INTEGRATION.md, "A stale pin").
- **A KG client given its service explicitly keeps it.** A client given
  `daemon_url`/`_api_key`/`_expected_build_id` no longer replaces that
  service with whatever the environment and `daemon.json` name when it
  re-reads its configuration after a host start.

## 0.7.0 — 2026-10-24

### Added

- **`metacodes --resume <id>`** starts the interactive REPL in a stored
  session of the working directory (an id or id prefix, as `/resume <id>`
  takes), with its conversation, goal and model route restored; the next turn
  appends to the same transcript. An unknown id exits 1 before the REPL
  starts. Combining `--resume` with another mode (`-p`, `--web`, `serve`,
  `--resume-response`, `--session`, `--teammate`, `--dump-*`) is a usage
  error. As in Claude Code, an interactive exit (`/exit`, Ctrl+C or Ctrl+D
  twice, EOF) from a session whose transcript is on disk now ends with a dim
  `Resume this session with:` / `metacodes --resume <id>`; a session that
  never ran a turn, and a non-terminal run, print nothing.
- **A resumed session shows its conversation.** `metacodes --resume <id>`
  writes the conversation back under the banner, and `/resume <id>` clears
  the screen and does the same before its result, as Claude Code does: the
  prompts, replies and tool cards look exactly as they did live (the last 200
  messages at most, after a dim `… N earlier messages` line). Text the runtime
  wrote into the conversation itself (continuation requests, nudges, job
  notifications, a Skill's body) is not shown, here or in Ctrl+O, and
  `/recap` labels it `Host`: such messages now carry `"origin":"host"` in
  `transcript.jsonl` (older records load as before).
- **`skillOverrides`, and `/skills` to set them** (Claude Code's per-Skill
  setting, same files: user < project < local settings). `name-only` lists a
  Skill to the model without its description; `user-invocable-only` hides it
  from the model and the Skill tool refuses it, while `/name` still runs it;
  `off` also refuses `/name` (`Skill "x" is disabled via skillOverrides. …`)
  and drops it from the `/` menu. In the TUI, `/skills` shows each Skill's
  state (`✔ on`, `● name-only`, `◯ user-only`, `✘ off`; a
  `disable-model-invocation` Skill is locked) and Enter or Space cycles it;
  closing writes `.claude/settings.local.json` and prints `Updated N skill
  overrides` or `No changes`, and the next request carries the new listing.
  Without overrides the Skill listings are byte-for-byte unchanged.

### Changed

- **Interactive startup waits for less.** Every interactive start used to
  spend about 0.55 s asking the account endpoint for its API keys with the
  API key, which that endpoint always refuses, and about 0.25 s on
  `/v1/models`, and it played the 1.5 s splash only after all startup work
  had finished (measured 2026-10-23). The key list is now fetched the first
  time the `/models` key menu opens, with the stored login token, or with the
  API key only for an endpoint named by `METACODE_API_KEYS_URL`. Without
  either, no request is sent and the menu lists the key in use. The REPL keeps
  each route's `/v1/models` answer, per endpoint and credential, in
  `<state root>/cache/models/` for 24 hours. A start that finds a fresh copy
  uses it and refreshes it in the background, and the refreshed answer is
  used from the next turn on. A start without a fresh copy fetches the answer
  before the prompt, as before. The splash now starts before startup work and
  plays during it; the banner follows when both are done. In a PTY with those
  gateway latencies simulated, the time to the banner went from 0.94 s to
  0.14 s (0.39 s on a first start) without the animation, and from 2.46 s to
  1.66 s with it.
- **The REPL no longer waits for MCP servers before showing its prompt.**
  Servers connect in the background (the footer reads `connecting to MCP
  servers (n/total)`); the first message, `/skill`, prompt command, `/btw`,
  `/recap`, cron or `/loop` turn waits for every server to report (spinner:
  `Connecting to MCP servers`; Esc or Ctrl+C stops waiting), then registers
  their tools and builds the tool list and system prompt once, so the first
  request is byte for byte the one a synchronous start sent. Measured with two
  stdio servers that take 3 s to start: prompt after 3.02 s before, 0.02 s
  now. Ctrl+C twice while a server is starting exits at once (its handshake
  is interrupted and the process reaped). `/mcp` shows servers that are still
  connecting, and after startup the footer announces failures once (`1 MCP
  server failed · /mcp`; a 401/403 reads `1 MCP server needs auth · /mcp`
  and `/mcp` marks it `needs authentication`). `-p`, `--web`, `serve`,
  `--teammate` and the dumps still connect every server before they start;
  their connects now overlap the rest of startup.
- **TUI: the prompt and commands behave like Claude Code 2.1.278** (recorded
  side by side in a PTY). Ctrl+C, and Ctrl+D on an empty prompt, exit on a
  second press within 800 ms; the first shows `Press Ctrl-C again to exit` in
  the footer and Ctrl+C discards the draft, with nothing written to the
  scrollback. Esc twice clears the draft into history (the first shows `Esc
  again to clear`); Esc on an open `/` or `@` menu closes it and keeps the
  draft. Ctrl+D with a draft deletes forward. Enter on a blank prompt does
  nothing. A local command's result hangs off `⎿` under its echo; an unknown
  command is reported in place of its echo with the closest command
  (`Unknown command: /foo. Did you mean /loop?`). `/help`, `/skills` and
  `/login` open bottom panes (tabs; a searchable Skill list; a provider list
  whose sign-in runs on a worker that Esc cancels, Metask included). `/clear`
  starts a new session with empty context, as it said it did. Skill
  invocations and `/init`, `/commit`, `/review`, `/retry`, cron and loop
  turns run through the interactive turn path (spinner, tool cards, Esc to
  interrupt) instead of a plain text stream, and a Skill's body no longer
  lands in the scrollback. The `/` menu is alphabetical and lists every
  command; the `?` panel uses Claude Code's phrasing; command output, turn
  notices and `/kg` are in concise English.

### Fixed

- **MCP over HTTP: one kept-alive connection per server, and no more
  dropped requests.** Every message used to open its own TLS connection with
  `Connection: close`, so a server cost about four handshakes at startup
  (2–2.7 s per server for the imported Codex / Claude Code servers measured),
  and Vercel-hosted servers such as developers.openai.com dropped those
  requests unanswered most of the time (`could not connect to the server
  URL`).
  Requests in quick succession now share one connection; an answered SSE
  stream is read to its end first, an idle connection is reused only within
  4 s, and a request that meets a reused connection the server already
  closed is sent again on a new one.
- **The system prompt keeps naming the model `/model` switched to.** With
  `--model-display-name`, a `/skills` change, a working directory renamed
  under the session, or `EnterWorktree` / `ExitWorktree` after a `/model`
  switch rebuilt the prompt with the startup display name again (the switch
  itself named the new model). Every rebuild now names the same model: the
  display name until a switch, the switched model after one.
- **`KgRemember` no longer writes the host's own TinyKG types.**
  Self-evolution keeps provisional rules, their retractions, task
  obligations, verifier outcome rows and obligation telemetry in the store
  the memory tool writes to, and reads them back by schema type without
  asking who wrote them; the rule author's ontology snapshot reads
  `proposition`, `prescription` and `intent` the same way. The model could
  store a well-formed envelope under one of these types (text in a
  repository file was enough to ask it to), and the next headless run with
  `METACODES_SELF_EVOLUTION=1` enforced a planted rule, dropped a learned
  one, nudged toward a planted obligation, retired a needle, or showed the
  attempt a rewritten outcome; a bare `proposition` made the ontology
  snapshot fail (`InvalidRecord`). `KgRemember` now refuses these types and
  the provider decision audit type, in any letter case, with
  `ReservedMemoryType` (a permission denial naming the type); `lesson` keeps
  its learning-turn admission, and the host's own writes are unchanged.
  Nodes the model already stored under these types are not removed.
- **`/model` lists every provider.** The picker's provider rows grouped by a
  label that pointed into the loop's copy of each offer, so providers whose
  ids have the same length shared one row: `metask`, `openai` and `gemini`
  showed as `metask 16 models`, and Enter on it listed only Metask's models,
  leaving the OpenAI and Gemini routes unreachable from the picker. Each
  provider now has its own row.
- `zig build test:picker` and `zig build test:provider` compile again, and
  `zig build test` now runs both. A test in `src/api/model_name.zig` imported
  the system prompt, and the provider kernel reaches that file through
  `util/pricing.zig`, so both isolation roots compiled the whole application;
  once the formal runtime needed a build option they stopped compiling (`no
  module named 'project_harness_build_options'`). The test moved to
  `src/api/model_name_consumers_test.zig`, and `types.zig` declares the stall
  gate setting instead of importing `core/stall_gate.zig` for it. `zig build
  subsystem:boundary` now checks every file a subsystem reaches, test blocks
  included, and the picker's own files are its two files rather than all of
  `src/repl/`. The four tests in `src/provider/capability_matrix_test.zig`,
  which only the provider root reaches, had never run in CI.
- Linux and macOS CI now run the platform layer's `terminal.zig` and
  `timezone.zig` tests. The "Native platform modules" step listed the modules
  to test by hand, and the list missed both; their 7 tests ran only on the
  Windows gate, where the time zone's daylight-saving test skips. The step now
  compiles `src/platform/platform.zig`, whose test block references every
  module it exports. `zig build test` also runs `test:platform` (its fork tests
  still need `METACODES_PROC_TEST=1`) and `test:lsp`, which until now ran only
  in `windows:gate`, so `gate:pr` covers both locally.
- An OpenRouter catalog ingested at runtime keeps its strings. Its channels
  borrowed model ids, names, regions and control specs from the parse results,
  which the ingest frees before it returns, so the registry profile and every
  offer catalog built from it (now or on a later refresh) read freed memory.
  `buildChannels` now copies everything the channels point at into the
  profile's arena.
- **`--api-key` no longer authenticates another provider's `/model` pick.**
  The flag names no provider: without `--provider` it is the Metask key, after
  `--provider X` it is X's. A commit in the `/model` picker or `/model use`
  passed it to whichever offer was chosen, ahead of that provider's own
  environment key, so `metacodes --api-key <Metask key>` followed by picking a
  Z.AI, OpenAI or configured-relay model sent the Metask key to that vendor,
  and `--provider X --api-key` sent X's key to the Metask gateway. The flag now
  binds only offers of the provider the session started on. Another provider's
  pick uses its own credential, or is refused for want of one (an OAuth
  provider offers its sign-in) and the previous route stays active.
- **TUI: a terminal resize no longer answers an open dialog.** A resize
  interrupts a blocked key read (SIGWINCH has no `SA_RESTART`), and the
  permission dialog took the interrupted read for "No": the tool was denied
  (`user declined 'Write' via prompt`) before any key was pressed.
  AskUserQuestion failed with `InputAborted`, and the pager, the Ctrl+O
  transcript viewer, reverse search and a paste in progress ended the same
  way. An interrupted read is now retried and the dialog is drawn again; a
  SIGINT that asks the process to stop still ends it.
- **`/model` on a Metask API key lists the models that key can use.** With no
  `--provider` and no Metask session login, the picker showed the six compiled
  Claude models at `napi.metask-ai.com` whatever the key's gateway served or
  `--base-url` named, marked none of them current, and picking one with a key
  stored by `metacodes login` asked for a sign-in (`MissingCredentials`). The
  Metask row now holds the models the session's gateway answers on
  `/v1/models` (again after a `/models` key switch), at the session's own
  endpoint, one Messages route each; the running model is marked, and a pick
  is sent with the session's key — the one picked in `/models`, else the one
  it started with. With no answer from the gateway the compiled list stays.
- A provider catalog ingested at runtime no longer frees another one's. The
  host kept one arena for all of them, so Metask's gateway catalog arriving
  after a configured `provider_catalogs` entry released that entry's profile,
  and the rebuild in the same ingest read it.
- The sharded test runner gives `std.debug` and every test a private copy of
  the start-up environment. Both read the start-up `envp` array lazily, and a
  test's `setenv` could make macOS free a string that array still pointed at;
  the first `std.debug.print` in a shard then panicked in the environment
  scan (`start index 3 is larger than end index 2`) whenever an earlier test
  in that shard had moved `HOME` the wrong way.
- `zig build test` no longer leaves TinyKG services from the WorkBuddy replay
  tests. `WorkBuddyLeaderboardProtocolTest`'s window replay and
  `LeaderboardPreflightBinaryTest` arrived after the earlier fix. They run the
  real binary in a throwaway HOME with the adapter's environment, which keeps
  the trial's local TinyKG. Each run left three
  `metacodes --state-dir <deleted temp dir> kgd` processes with their
  `tinykgd` children (a developer machine had 48 pairs after four days). The
  replay now stops the service it started, and it fails if one is still
  running under its temporary directory. Autostart stays on, so the replay
  still runs the trial's configuration.
- **A dead connection is no longer waited out for half an hour.** A session
  on glm-5.3-flash received the response head and `message_start`, then no
  byte for 1801 s, not even the gateway's keepalive pings, which that
  gateway sends at least every 15 s while healthy; the turn ended with
  `正文空闲超时` after the full 30-minute body limit and needed a manual
  `/retry`, which finished in 18.7 s. Each provider client now learns how
  often its endpoint sends a keepalive mid-stream (a ping or SSE comment
  that ends a silence of at least 2 s, after the stream has produced
  output; three such samples arm it). On an endpoint that has shown this, a
  streamed body with no byte at all, keepalives included, for 4 × the
  longest interval seen (at least 2 minutes) is judged dead, and the TUI
  prints `连接已断: … 连 keepalive 也没有…`. The verdict resets what was
  learned, so an endpoint that stops sending keepalives is judged by the
  body limit again. An endpoint that never sent a keepalive mid-stream
  keeps the old behaviour.
- **A stream that gave no answer is re-sent once, in the TUI too.** The TUI
  never re-sent a turn that failed mid-stream, so as not to repeat text the
  user had already watched. When the stream stalled, or ended without
  reporting how it stopped, or the connection dropped, before any text,
  thinking or tool call arrived, there is nothing to repeat, so the same
  request is now sent again once (headless keeps its two retries). An error
  the server reports in the stream is an answer and is not re-sent, and
  neither is a local failure such as an over-long line. A body-phase stall
  on an upstream that is pinged alive can therefore take up to two body
  limits before the turn ends.
- **An error a server reports mid-stream is reported as one, on every
  wire.** On OpenAI-compatible chat and Gemini streams a `data:
  {"error":{…}}` chunk was skipped as empty; the stream then ended without
  a stop report and read as an unterminated stream, so the server's own
  message never reached the user. It now ends the turn with
  `API 错误帧: <the error object>`, as Anthropic's error frame already did,
  and OpenAI Responses' `response.failed` and `error` events do the same
  instead of the generic request failure. Mid-stream, the generic request
  failure now means only that the connection dropped; local failures (an
  over-long line, out of memory) keep their own names.

## 0.6.0 — 2026-10-20

### Added

- A startup animation in the interactive TUI: the wordmark "Metask Lab"
  condenses out of a particle brightness field and is drawn only with the
  letters of its own name (after chenglou.me/pretext's variable typographic
  ASCII), then stays above the welcome box. It adapts to the terminal's colour
  depth and light or dark background, plays only when stdin and stdout are both
  terminals and the wordmark fits, and any key jumps to the settled frame.
  `METACODES_NO_STARTUP_ANIMATION` set to any value, or `"startupAnimation":
  false` in `<state root>/config.json`, turns it off. On Windows a bare
  modifier key (Shift, Ctrl, Alt) skips it without blocking, and no frame is
  drawn after the terminal changes size. The REPL's post-reply input drain
  uses the same non-blocking discard, so a bare modifier pressed during a
  reply no longer holds the next prompt on Windows.

- Python and Node packages over the AgentCore shared library (`sdk/python`,
  `sdk/node`; experimental, not yet published). Both offer a Runtime/Session
  API, streaming events, the final answer rebuilt from output segments, tools
  written in Python or JavaScript (async in Node), permission and question
  requests, abort and mid-Run input, and refuse any library whose ABI revision
  differs. Python uses ctypes and has no dependencies; `build_wheel.py` makes a
  reproducible platform wheel with the library and ripgrep inside. Node uses a
  Node-API addon compiled with `zig cc` that runs each Run on its own thread.
  The new `sdk-bindings` CI job (Linux, macOS; not required) runs both
  packages' end-to-end suites against a loopback mock provider, including the
  installed wheel.

- Session goals at every entry point, and in AgentCore (issue #277).
  - **One set of rules.** `core.goal` owns the status table: pause needs an
    active goal, resuming a goal whose budget is used up is refused until the
    budget is raised (in the same update if wanted), a complete goal cannot be
    blocked. Refusals change nothing; objectives are 1-4000 code points.
  - **Accounting by the agent loop.** Each provider response's non-cached
    input plus output (automatic compaction included) is charged to the goal
    a Run began on while active, and the Run's time when it ends - a Run that
    ends in an error included. A budget used up mid-Run makes the goal
    `budget_limited` and asks the model once, at the next turn, to wrap up;
    the Run is not cut off.
  - **CLI.** REPL, web, daemon, forked Skills and headless all charge the
    session's goal (web, daemon and headless never did, though a resumed
    daemon session loaded it), and goal.json is written whenever it changes.
    `/goal resume` past a used-up budget now says so instead of reactivating.
  - **AgentCore Revision 23.** A sixth root table, `goal`, with `get` (JSON),
    `set`, `update` (objective, budget and action together or not at all)
    and `clear`; the root grows from 64 to 72 bytes. A
    `RUN_INPUT_GOAL_CONTINUATION` Run's input is written by the runtime from
    the goal. Status 30 `GOAL_CONFLICT`; the `goal_updated` event; a goal
    section in checkpoints (marker 10), admitted against the durable budget.
  - SDK 0.10.0-dev.
- Host-scheduled teams in AgentCore and at the Swarm entry points (issue #277).
  - **Host scheduler.** With `enable_teams`, a lead Session delegates with
    `SpawnTeammate` by recording a spawn request instead of starting an
    in-process thread; the embedding Host creates and runs each member
    Session. `TeamCreate`, `TeamDelete`, `SendMessage` and `SpawnTeammate` are
    Session-owned team builtins, admitted only by the flag. Team membership is
    Host-supplied at create and restore and carries no checkpoint state.
  - **AgentCore Revision 24.** A seventh root table, `team`, with `describe`
    (team roster and pending spawns as JSON) and `poll` (the lead's next queued
    input, marked read); the root grows from 72 to 80 bytes.
    `RuntimeConfigV1.enable_teams` admits the team tools and
    `SessionHostConfigV1.team` (`TeamConfigV1`, lead or member) joins a Session
    to a team.
  - SDK 0.11.0-dev.
- Date and time zone for the model at every entry point (issue #276).
  - **CLI.** The user-context message always states the date the session
    started on, with its time zone - without CLAUDE.md, memory or KG, and
    with `CLAUDE_CODE_DISABLE_CLAUDE_MDS` set - as
    `Today's date is 2026-10-17 (Saturday). Time zone: Asia/Shanghai (UTC+08:00).`
    The zone is the process's: libc `localtime_r` on POSIX (honours `TZ`,
    `/etc/localtime` and daylight saving), the dynamic time-zone information
    on Windows. When neither answers, the date is in UTC and the text says
    the zone is unknown.
  - **Crossing midnight.** The first Run on a later local date gets one
    "The date has changed" notice after its input, in that turn's history.
    The system prompt and the first message do not change, so the prompt
    cache survives midnight. A notice that compaction, trimming or `/clear`
    removed is given again.
  - **AgentCore Revision 22.** `RunOptionsV1.time_context_code` and
    `utc_offset_minutes` take the first remaining reserved word, so the
    layout is unchanged at 40 bytes. By default each Run's context starts
    with a `currentDate` block in the process's zone.
    `TIME_CONTEXT_UTC_OFFSET` dates it in a Host-given offset (UTC±14:00)
    instead, and `TIME_CONTEXT_OFF` drops it.
  - **Host precedence.** A Host block labelled `currentDate` replaces the
    runtime's. Combined with an explicit offset it is refused as
    `INVALID_ARGUMENT`.
  - **Source-level Hosts** build the same block with `core.time_context`.
  - SDK 0.9.0-dev.
- Learning turn, kernel side ([doc/LEARNING_TURN_DESIGN.md](doc/LEARNING_TURN_DESIGN.md)):
  `agent_loop.Options.learning_turn` (enforce or observe). When the host
  check gate's verdict ends a root run, the same conversation gets one
  distill message carrying the verdict and the stored lessons for the task,
  and writes up to four conditioned lessons with `KgRemember` kind `lesson`
  (`holds_when:`, `uncertain:`, `lesson:`, optional `supersedes:`); a
  reconcile message follows only when a lesson was accepted and stored
  lessons exist. The lesson header (`lesson-v1 verdict= task= run=`) is
  host-bound: `KgRemember` refuses kind `lesson` outside a learning turn
  and any header that differs from the verdict the host saw. During a pass
  only Read, Grep, Glob, KgRecall, KgContext and KgRemember run, process
  gates neither sense nor end it, and the attempt's answer stays the final
  result. Each pass is capped at six model turns. Tainted, unavailable and
  unchecked verdicts teach nothing, and neither does a run with no ready
  TinyKG store (`none_unstorable`). The next attempt at a hinted task sees
  the newest unsuperseded lessons in the scoped-recall injection (no
  lessons, byte-identical injection). One terminal `learning_turn`
  observation record per armed run (`metacodes-learning-turn-v1`, validated
  by `scripts/eval/workbuddy/trace.py`).
- Learning turn, host side (design steps 5–8): `--learning-turn` /
  `--learning-turn-observe`, and `METACODES_LEARNING_TURN=enforce|observe` in
  print mode (a flag wins). The flags need a verdict source and are refused
  without one, like `--check-gate` without `--host-check`: the check gate
  (REPL and print mode; it arms the in-run turn, with
  `METACODES_TASK_HINT` as the task and the journal run id in lesson
  headers), or in print mode the self-evolution host check
  (`METACODES_HOST_CHECK` with `METACODES_SELF_EVOLUTION=1` and a task hint).
  After that host check, when the attempt ended on its own and the in-run
  turn had no verdict, the end-of-run form spends one no-tools provider
  request under the self-evolution author caps (tokens and cost, checked on
  the provider's reported usage) and writes the lessons its response carries
  through the same header binding `KgRemember` enforces; every envelope that
  claims another header counts as refused. `LearningTurn.lean` mirrors the
  policy and proves, over any event trace, at most two passes and two host
  messages, at most six turns per pass and four lessons, reconcile only after
  an accepted lesson, no message in observe mode, and the answer closed
  before any learning message. `evals/experiments/learning-turn-v1.md`
  preregisters the paired evaluation (development configuration with the
  validator pinned, held-out configuration with the visible suite pinned,
  stopping rules); nothing has been run.
- Chained-attempt evaluation runner: `scripts/eval/cli.py run-chained` runs
  K sequential attempts per task, per arm and per replicate on one TinyKG
  store that starts empty and is carried from attempt to attempt
  (`tests/e2e/lib.sh` `import_kg_store` extracts the previous attempt's
  exported store into the fresh fake HOME before the session and writes an
  import witness outside the workspace), with `METACODES_TASK_HINT` set to
  the task id and one TinyKG domain per task (`METACODES_KG_DOMAIN`; the
  default follows each attempt's new git root, so project-scoped lessons
  would never be recalled by the next attempt). Rollouts keep the
  `run-paired` format (`trial = replicate × attempts + attempt − 1`); a
  per-arm hash-chained ledger (`metacodes-chain-ledger-v1`) links each
  attempt's import to the previous export and fails closed on any break,
  changed archive, missing witness or ledger/checkpoint disagreement. The
  store is exported before the offline grade runs. `--budget-journal` and
  all four caps are required (validated by `run-paired`'s own rules); every
  attempt is reserved, authorized and committed in the durable budget
  journal, and an attempt that fails after authorization is recorded as
  failed, stays charged at its full allowance and is never re-run by a
  resume. `scripts/eval/chained_memory_smoke.py` (`zig build test`, loopback
  provider) shows a lesson written in attempt 1 reaching attempt 2's request
  through the real binary and harness, and not without the fixed domain.
  `learning-turn-v1.md` records its launch prerequisites
  as met except a pinned full-validator command for configuration D, and an
  amendment: the REPL harness files no outcome rows, so the baseline is the
  accumulating store without lessons.
- `evals/validators/check_gate_v3_pinned.py`: the fixed check-gate command
  for learning-turn-v1 configuration D. It runs the full validator of the
  task named by `METACODES_TASK_HINT` against the workspace and exits 0/1
  with the validator's verdict only when the last of its count (or timeout)
  lines agrees with its exit status - the last verdict line, not the last
  line, since the tests' stderr follows the count line and the candidate's
  code may write there; anything else, including a validator that crashed
  with exit 1 and printed no verdict line, is 127 (`unavailable` to
  the check gate), so a broken check never becomes a lesson. The protocol
  records the command line and the exposure it implies (hidden test names in
  the verdict, the validators readable at the quoted path); prerequisite 3
  stays open until tool calls naming `evals/validators` are counted per arm,
  which is not implemented yet.
- Sealed Skills: the §8.5 disclosure screen keeps two corpora under their
  own policies — the Skill's instructions and its `sealed/` references —
  so `egress.disclosure` is one word for both or
  `{"body": "redact", "references": "off"}`. A documentation Skill whose
  references were being replaced by `[sealed]` when cited (seen with the
  Browser Use Cloud reference skill) sets `references` to `off` and keeps
  its instructions screened; the install summary shows both policies.
- AgentCore Revision 21: Host model-capability declarations (issue #273).
  `SessionHostConfigV1.model_capabilities` / `model_capability_count` (two
  former reserved words; the struct stays 168 bytes) carry up to 256 40-byte
  `ModelCapabilityV1` entries, each saying whether one model takes image input
  (`CAPABILITY_SUPPORTED` / `CAPABILITY_UNSUPPORTED`). A declaration outranks
  the provider catalog and the built-in model-family table for the Session's
  model, every `set_model` target and its tool-scoped providers, and a restore
  uses the current Host's declarations. `describe` reports
  `"image_input":{"supported":…,"source":"host"|"catalog"|"model_family"|"unknown"}`.
  Source-level hosts pass the same through `SessionConfig.model_capabilities`;
  `Provider.imageInput` answers with the source. The OpenAI and Gemini clients
  now apply a catalog's `image_input` declaration too (only the Anthropic
  client did), and the CLI hands them the Metask catalog. SDK 0.8.0-dev.
- Sealed gateway at scale ([doc/SEALED_GATEWAY_SCALE_DESIGN.md](doc/SEALED_GATEWAY_SCALE_DESIGN.md)):
  `metacodes sealed serve` runs a bounded worker pool with a queue and a cap
  on in-flight model calls, refuses over-capacity requests before reading
  them (HTTP 503 + `Retry-After`, or JSON-RPC `rate_limited` with
  `retry_after_ms`), answers Steps as SSE with keepalive comments, and lends
  each client's provider from a route-keyed cache so consecutive Steps do
  not rebuild it (`--workers`, `--queue-depth`, `--max-model-calls`,
  `--keepalive-ms`, `--provider-cache-ms`). The client resends a refused Step
  unchanged after the named wait. `zig build sealed:bench` measures Steps per
  second and gateway overhead against a mock upstream; its first runs removed
  a 16 MiB per-connection buffer and raised the process-wide request-setup
  gate (`connection_gate.raiseProcessLimit`) for the server, taking 64
  concurrent clients from 249 to 1 835 Steps/s.
- Sealed Skills: the §8.5 disclosure screen. Before a Step leaves the
  gateway, its `final` text, every call input of a `tool_calls` batch and
  any question pass a screen built from the Skill's sealed material (the
  body and the `sealed/` files): every run of eight consecutive tokens that
  also occurs there is replaced by `[sealed]`, the Step carries
  `disclosure.redactions`, and the client logs it, records it in the ledger
  and tells the user once; the brain's own conversation keeps the original.
  The manifest's new `egress.disclosure` chooses `redact` (default), `fail`
  (the run ends as `failed` / `disclosure`) or `off`. Numbers, names, short
  phrases and paraphrases pass; the document says so.
- Sealed Skills: `egress.classes` is enforced at run time. A call whose
  result class the client can tell from the tool (`Read`/`Grep`/`Edit`/
  `NotebookEdit` → `file_contents`, `Glob` → `repository_structure`,
  `Bash`/`BashOutput` → `command_output`, `WebFetch`/`WebSearch` →
  `page_snapshot`) is refused unexecuted as a `policy_violation` when the
  pinned manifest does not declare that class, and counted toward the
  three-violation cancel like an allowlist refusal. The sealed fork's
  system prompt carries the codebase context (the CLAUDE.md chain and git
  status) only when the manifest declares `repository_structure`; the
  install consent now says what travels with each run besides tool results.
- Sealed Skills: a `Glob` or `Grep` whose target lies under the Skill's
  `sealed/` directory is answered on the gateway inside the Step, by the
  client's own tool implementation run against the package with every path
  it prints rewritten to the client's view; before, the call went to the
  client, which has no such directory and answered with no matches. The
  gateway serves `Read`, `Glob` and `Grep` on sealed files only for a tool
  the manifest admits, forwarding the call otherwise so the client refuses
  it; the manifest's tool rules are now one shared function
  (`protocol.manifestAllowsTool`).
- Sealed Skill chain and state: every Step derived from a `runs.continue`
  carries `results_digest`, the digest of the results array the gateway
  received, inside its digested body; the client computes the same digest
  before sending, checks the echo and ends the run on a mismatch (§8.3).
  The provider route and credential are re-read from the session's provider
  before every gateway request. `run_state` carries only the conversation's
  active window plus the compaction summary, restored as the first
  assistant turn, instead of every message ever exchanged. §8.4 now states
  what a stateless gateway does and does not prevent about replay.
- Sealed Skill audit and trace: the ledger now records every call's id and
  name per Step and a `results` record per `runs.continue` with the SHA-256,
  size and flags of each result as sent (§6.6); the client logs every
  gateway exchange and every Step at info level under `sealed`, and the
  gateway logs each Step it emits with its number.
- Sealed Skills run as a shadow of the client's fork on the client's own
  model account ([doc/SEALED_SKILL_PROTOCOL.md](doc/SEALED_SKILL_PROTOCOL.md)
  §8.1, §9): the gateway has no provider of its own; `runs.start` carries
  the fork's system prompt, tools, model and request parameters plus the
  client's provider route, and the credential travels in the
  `Sealed-Provider-Credential` header of each request. The gateway's brain
  is the real agent loop with a capturing dispatcher — every tool use
  suspends the loop and becomes a Step, the loop's continuation travels in
  `run_state`, and the gateway keeps nothing between Steps. The shadow's
  model request is byte-identical to a local fork's (an L2 asserts it);
  narration between calls stays on the gateway. Packages gain `sealed/`
  reference files read on the gateway and public assets installed under the
  pin directory (`sealed/skills.asset`). `metacodes sealed serve` drops its
  provider flags. Kernel seams: `Provider.route()`,
  `agent_loop.Options.suspend_all_pending` with `resumeRunWithResults`, and
  `transcript.Writer.renderMessageJson` / `parseMessageJson`.
- Sealed Skills, client side of the three §9.1 gaps: a call marked
  `confirm: true` is approved interactively whatever the permission mode,
  through a tightening-only confirm gate on the child's permission context
  (a remembered "allow always" does not answer it); credential references
  are bound per Skill with `metacodes sealed bind|unbind` in
  `<state root>/sealed-credentials.json`, substituted into the call's input
  and redacted from its result before it leaves the machine, an unbound one
  refusing the call with `permission_denied` and the bind command; an
  `input_required` Step is asked through the session's dialog and the answer
  continues the run. The reference gateway maps the brain's
  `AskUserQuestion` to `input_required` and annotates calls with the
  credential references their inputs name.
- Sealed Skill Protocol (SSP/1, [doc/SEALED_SKILL_PROTOCOL.md](doc/SEALED_SKILL_PROTOCOL.md)):
  a Skill whose body stays on a gateway while every tool call it needs is
  executed, approved and paid for on the client. `metacodes sealed install`
  pins a gateway manifest after showing the allowlist, egress classes and
  price; the pinned Skill runs as a fork whose model is the gateway, with a
  per-run cost cap (`METACODES_SEALED_MAX_COST_MICROS`) and a usage ledger
  (`metacodes sealed ledger`). `metacodes sealed serve` is the reference
  gateway: stateless, AEAD-sealed run state, metering per Step.
- AgentCore ABI v1 revision 20 (#270): `session->submit_input` hands an active
  Run more user text. It may be called from any thread or from inside the
  Run's own callbacks, like `session_abort`, and never waits for the Run. Each
  input carries a non-zero Host `input_id` (unique within the Run) and gets a
  1-based acceptance `sequence` in its receipt. The Run appends every pending
  input verbatim, in acceptance order, as its own user record at its next turn
  boundary — never into a request already sent, never at a `max_tokens`
  continuation boundary — and emits `input_adopted {input_id, sequence, turn}`
  for each. Input waits while a Permission or question request is pending and
  never answers it. A Run that ends before another boundary leaves its pending
  input unadopted. `RunResultV1.input_accepted_count` and
  `input_adopted_count` are defined on every `session_run_input` return,
  failures and poisoning ones included: adoption is always a prefix of
  acceptance, so the counts tell the Host exactly which inputs reached the
  Conversation even when an event was lost. Limits: 64 inputs and 16 MiB of
  text per Run (`MAX_SUBMITTED_INPUTS_V1`, `MAX_SUBMITTED_INPUT_BYTES_V1`);
  each input reserves its checkpoint bytes against the durable budget, counts
  with the root input toward `input_cap_bytes`, must leave room for one whole
  provider operation, and is refused with `CHECKPOINT_BUDGET_REQUIRED` —
  without ending the Run — when it does not fit. Once a Run is aborting (an
  abort, or a callback the Host failed) it adopts nothing more. A refused
  submission changes nothing; a stale id is `STALE_RUN`, a Run that ended or
  is ending `TOO_LATE`, a forked Skill Run `INVALID_STATE`.
  Adopted input is ordinary Conversation state and survives checkpoint and
  restore. The Session table grows by one slot to 48 bytes and `RunResultV1`
  turns its first reserved word into the two counts; the header, Zig and Rust
  SDKs (`raw.rs` regenerated), both source-free consumers, the bundle manifest
  and the docs move to revision 20, SDK package `0.7.0-dev`. Source-level
  Hosts use `AgentSession.submitInput` / `runInputReconciliation`.

- Skills and MCP servers configured for Claude Code and Codex now work in
  metacodes, next to its own `<state root>/skills` and `config.json`
  ([doc/SKILLS_AND_MCP.md](doc/SKILLS_AND_MCP.md)). Skills come from
  `~/.agents/skills`, `~/.claude/skills`, `~/.codex/skills`, the managed
  directories, every project level from the repository root to the working
  directory, and `--add-dir`; MCP servers from `mcpServers` in metacodes'
  config, `~/.claude.json`, an approved `.mcp.json`, and Codex's
  `config.toml` (trusted projects only for project layers).
- MCP 2026-07-28: `server/discover`, per-request `_meta`, `resultType`, and
  input-required retries (MRTR), with the `initialize` handshake (2025-11-25
  down to 2024-11-05) as fallback; Streamable HTTP servers (JSON and SSE
  responses, session headers, `Mcp-Method` / `Mcp-Name` / `x-mcp-header`,
  bearer token from an environment variable); `tools/list` pagination; answers
  to server `ping`s; `notifications/cancelled` on interrupt or tool timeout.
- Typing `/` suggests Skills alongside the built-in commands (with
  `argument-hint`); the menu scrolls with the selection. `/skills` and `/mcp`
  show where each Skill or server came from and why anything did not load.
- Two more Session settings a source-level Host can change while idle.
  `SessionConfig.reasoning_effort` and `AgentSession.setReasoningEffort` set
  the effort every provider request carries; `setModel` keeps it, and a
  provider without an effort control refuses a non-null value at create.
  `WorkspaceConfig.additional_dirs` and `AgentSession.setAdditionalDirectories`
  give a Session further working directories (existing directories only):
  `accept_edits` approves
  Write/Edit/NotebookEdit there and a sandboxed shell may write there, exactly
  as for the workspace root. A replacement is validated before the Session
  changes. doc/API.md now tabulates which settings are idle-mutable, which
  need a new Runtime generation, and which are fixed at create.
- `protocol.wire`: versioned JSON lines for Hosts that carry a Session across
  a process or network boundary. `writeEvent`, `writeRequest` and
  `writeRequestClosed` produce `{"v":1,"type":...}` lines; `parseResponse`
  reads a client's answer back, treating anything malformed as a cancellation
  (closed as `malformed`) and an answer that races an interrupt as cancelled
  (also in `--web`). Hosts previously ran `std.json` over kernel structs, so a
  renamed field changed their clients silently. One pinned line per event
  tag and request kind lives in `tests/fixtures/wire/v1`.
- `session_host.SessionHost`: the multi-session service a network Host puts
  behind its own transport. Sessions open and close by id (fresh, or resumed
  from their transcript), submissions and configuration commands run in one
  FIFO per Session on its driver thread, every event lands in a replayable
  journal as wire lines with `run_id`/`trace_id`, UI requests are answered by
  id, `interrupt` also releases a pending prompt, a poisoned Session is
  reported and refuses work, and `close` frees the id at once while holders
  keep a readable shell until they release it. A cloud
  Host had rebuilt this by hand with a 5-minute watchdog, an interrupt that
  could not reach a pending prompt and a fresh session that resumed the old
  transcript; this is the kernel-side version. `EventJournal` moved from
  `web/` to `core/event_journal.zig` and is exported.
- `GET /health` on `--web`, `serve` and `serve --sessions` (#251): `200
  {"status":"ok","version":"<v>","sessions":N}`, unauthenticated and
  independent of any session, for container liveness and readiness probes.
  `version` is exactly what `metacodes --version` prints first, so an
  orchestrator can check the running release against the one it pinned.
- Bearer-token authentication for that HTTP surface (#252):
  `METACODES_WEB_TOKEN` (or `--web-token`, visible in `ps`) makes every route
  but `/health` require `Authorization: Bearer <token>`; a GET may pass
  `?token=` (EventSource, opening the browser UI), a POST may not. A wrong or
  missing token is `401` with `WWW-Authenticate: Bearer`, decided before any
  request body is read and compared in constant time. The bundled UI is
  opened as `/?token=<token>`; it drops the token from the address bar and
  sends it on every request. Without a token, requests whose `Host` is not a
  loopback name are now refused (DNS rebinding), and a POST's `Origin` is
  compared with its own `Host` (`[::1]` and TLS-terminating proxies work).
  Unset, local use is unchanged. The `--uds` transport keeps its 0600
  socket-file access control.
- `--web-bind <addr>` / `METACODES_WEB_BIND` (#253): bind the HTTP surface to
  any IPv4 or IPv6 literal (`0.0.0.0`, `::` dual-stack, `::1`, ...) instead of
  only `127.0.0.1`; the startup line shows the address actually bound. A
  non-loopback address without a token exits 2 unless `--web-allow-unauth` is
  given. Normative rules: [doc/API.md](doc/API.md#web-and-daemon-http-surface);
  trust model: [SECURITY.md](SECURITY.md#web-and-daemon-trust-model).
- A `--web`/`serve` message can carry its turn's configuration (#255):
  `POST /message` (`/s/<id>/message` under `serve --sessions N`) and the UDS
  `message` op take optional `model` and `permission_mode` beside `text`. The
  session applies them right before that message's turn — the model for this
  session only, without writing the login's saved selection as `/model` does —
  and journals one `config_changed` line per given field ahead of the turn's
  `user_message`. A bad `permission_mode` is refused with 400 before anything
  is queued; a model the provider cannot serve, or a mode the settings
  disable, applies neither field, runs no turn and journals
  `message_rejected`. A control plane no longer has to send
  `/command`, poll `/state` and race a busy session before each message.
  `/state`'s `seq`, `permission_mode` and `pending_request_id` are documented
  for reconnecting clients (doc/API.md).
- Dynamic sessions in the multi-session daemon (#254): `GET /sessions` lists
  the live sessions (`generating`, `model`, `permission_mode`,
  `pending_request_id`); `POST /sessions/create` (`{"session_id"?,
  "resume"?}`) starts one, under the caller's id or a generated one, and with
  `"resume":true` rebuilds its conversation from the transcript persisted under
  the state root, so a session survives a container rebuild;
  `POST /sessions/<id>/resume` answers 200 when the session is live and 404
  otherwise; `POST /sessions/<id>/destroy` aborts its run and stops its
  background agent jobs, teammates and background shells, joins them all,
  ends every SSE stream and UDS attach with `session_lifecycle.closed`, and
  returns. `serve --sessions 0` starts with no session, and
  `--max-sessions M` (default 32) caps live sessions, answering 429 beyond it.
  Requests now hold a counted lease on the session they address for as long
  as they run (an SSE stream or UDS attach for its whole life); a destroy
  never waits for one and frees the session after the last is returned; until
  then its id is refused to a create (409 `session is still closing`). A
  create holds its connection while the session starts; after a timed-out
  create, check `GET /sessions`. Normative rules:
  [doc/API.md](doc/API.md#web-and-daemon-http-surface).

- The `--json` result line carries `continuations`: how many times the Run
  asked the model to continue an answer the provider cut at its output-token
  limit (`max_tokens`). The continued text is one seamless concatenation and
  the line still reads `end_turn`, so before this a headless consumer could not
  tell the answer had been truncated. Source-level Hosts read the same count
  from `RunResult.continuations` (issue #269).

### Changed

- CI is ready for GitHub's merge queue and skips suites a change cannot
  affect ([doc/CI_DESIGN.md](doc/CI_DESIGN.md)).
  - **Merge queue.** `ci.yml` and `agentcore-windows.yml` run on
    `merge_group`. The release fast path and the change scope diff a group
    against its `base_sha`. The version state gate judges the PR at the
    group's head, taken from the queue's ref, so a PR queued behind the
    release PR is dropped until the reopen PR merges. The ruleset switch
    (merge queue on, "up to date" off) is a separate maintainer step.
  - **Change scope** (`scripts/ci_scope.py`). Every required job still runs
    and reports.
    - A change that adds or edits only `doc/**` and the top-level Markdown
      the release layout does not install (everything but `README.md`,
      `CHANGELOG.md` and `THIRD_PARTY_NOTICES.md`) runs only the
      documentation, version-state and gate-manifest checks. Removing or
      moving a doc file runs everything.
    - A change confined to documentation, `scripts/eval/**` and `evals/**`
      runs the gates in full but skips the TTY suites.
    - Anything else, every push, and any doubt runs everything.
    - `scripts/tests/test_ci_scope.py` pins which steps run in each scope.

- `scripts/perf_baseline.sh`: the ReleaseSmall binary-size red line is 6 MiB,
  recalibrated from the 2026-10-18 measurement (5.50 MB); the 1.5 MB line was
  set on a 1.29 MB build in June. Startup and idle-RSS lines are unchanged.

- AgentCore provider requests now carry a `currentDate` context block in each
  Run's user record unless the Host supplies one or sets `TIME_CONTEXT_OFF`
  (Revision 22, issue #276). Hosts that byte-compare requests should set
  `TIME_CONTEXT_OFF` or pass their own block. The CLI's date moved from a UTC
  `YYYY/MM/DD` to a local `YYYY-MM-DD (Weekday)` with the zone named.

- An image Run for a model that no Host declaration, provider catalog entry or
  built-in model family covers now returns AgentCore status 29
  `IMAGE_INPUT_CAPABILITY_UNKNOWN` instead of 28 `IMAGE_INPUT_UNSUPPORTED`; 28
  now means a source says the model does not take images. Both still refuse
  before any provider request: an unknown route can drop an image without an
  error, so it is not sent on a guess (issue #273). Hosts that treated 28 as
  "pick another model" should treat 29 as "declare the model, or pick another".

- The Sealed Skill Protocol document says everywhere what the code does:
  the gateway holds no inference account. Roles and identities (§1.2: the
  subscriber's own provider account; the inference-gateway identity relays,
  meters and signs, owns nothing), `discover` (§3.1: `client_provider` MUST
  be `true`; `billing` bills the Skill fee, never the model), the budget as
  a cap on the estimate (§3.4), Step usage (§4.3, §8.2: the provider's token
  counts and the gateway's estimate both travel; model usage is billed on
  the client's own account, the gateway account owes only the Skill fee),
  the disclosure channel (§1.1, §8.5) and creator payment (§12).
  `doc/SKILLS_AND_MCP.md` no longer says usage is charged to the gateway
  account.
- `agent_loop.run` refuses provider server tools: a tool definition with
  `server_type` (in `tool_defs` or `Options.tool_defs`) returns
  `error.ServerToolsUnsupported` before any request (`resumeRun` and
  `resumeRunWithResults` before they append the resumed tool results). The
  loop keeps no server_tool_use or server result blocks, so a turn the
  server pauses (`pause_turn`) could only be truncated. `AgentSession`'s
  tool catalog already rejected them; only direct source-level callers of
  `run` are affected. For the same reason a Sealed Skill gateway refuses a
  `runs.start` whose `provider_tools` is not empty with `invalid params`
  naming the field, before any model call; the client's fork never sends
  one.
- `--web`/`serve`: `user_message` is journaled by the session when the
  message's turn starts, no longer by the transport when the message is
  queued, so it always means "this turn started with this text". A message
  sent while a turn runs now appears after that turn's `run_done`; the bundled
  page shows it as queued until then. Over UDS, the `message` text is trimmed
  and must not be empty, as over HTTP: an empty text is refused instead of
  queued and dropped, and a missing one is reported as `empty message` (was
  `missing text`).
- `config_changed` on the `--web`/`serve` stream is a `protocol.wire` v1 line,
  `{"v":1,"type":"config_changed","data":{...}}`, instead of
  `{"config_changed":{...}}`. The bundled page now updates its model and mode
  display from it; a client reading the stream directly must follow.
- `serve --sessions 1` now runs the multi-session daemon (one startup session
  under `/s/<id>/`, plus the `/sessions` routes), as doc/API.md already
  described; it used to fall back to the single-session `serve`. Plain `serve`
  is unchanged. `--sessions` takes a count of 0 or more and rejects anything
  else (it used to read a bad value as 1), and `--sessions`, `--max-sessions`
  and `--uds` without `serve` are argument errors (exit 2) instead of being
  ignored.
- Destroying or shutting down a daemon session now also cancels its in-flight
  provider request, so a session whose provider stopped sending stops at once
  instead of after the stream idle limit (up to 120 s by default). Stopping a
  background agent job or a swarm teammate (session close, App teardown) now
  cancels its in-flight provider request too, instead of waiting out that
  limit.
- MCP tools are named `mcp__<server>__<tool>` (Claude Code's form, so its
  permission rules and `allowed-tools` lists match); invalid characters become
  `_` and over-long or colliding names get a stable hash suffix. A subagent
  `tools:` list, a Skill's `allowed-tools` or a permission rule that still uses
  the old `<server>__<tool>` name keeps selecting the tool. The
  per-server `<server>__list_resources` / `__read_resource` tools are no longer
  registered; `ListMcpResourcesTool` / `ReadMcpResourceTool` serve resources.
- A Skill name clash now resolves enterprise > personal > project, as in Claude
  Code (it was project-first). Compat Skills reference their live directory —
  only `SKILL.md` and `agents/openai.yaml` are read at startup — and the
  activation result starts with `Base directory for this skill: <dir>`.
- A forked Skill's `agent:` runs it under that subagent's prompt, tool set,
  permission mode and model in the CLI (it used to make the Skill unavailable).
- AgentCore's MCP parser treats an absent 2026-07-28 `resultType` as
  `complete` and accepts the specification's `{method, params}` input
  requests, as the final 2026-07-28 schema requires.
- The `--web` event stream sends the `protocol.wire` v1 lines. Kernel events
  were `{"core_event":{"<tag>":...}}` and UI requests
  `{"ui_request":{"id":N,"request":{"<kind>":...}}}`; they are now
  `{"v":1,"type":"<tag>","data":...}` and
  `{"v":1,"type":"ui_request","id":N,"kind":"<kind>","request":...}`, with
  `ui_request_closed` replacing `ui_request_done`/`ui_request_cancelled` and
  `multi_select` replacing `multi` in questions. The bundled page follows;
  a client reading the stream directly must follow too.
- Breaking for source-level embedders: `transcript.Writer.init` and
  `transcript.listSessions` take the state root as a `StateRoot`
  (`util/state_root.zig`) instead of a `[]const u8`, so a bare path no longer
  compiles there; take the value from `WorkspacePolicy.stateRoot()`. On 2026-10-01 the third
  `Writer.init` parameter changed meaning from home to state root while keeping
  its type, so a Host that still passed `$HOME` compiled and wrote transcripts
  one level off from where it resumed them. New `transcript.sessionDir` and
  `transcript.projectDir` are the only definitions of the layout, and
  `WorkspacePolicy.stateRoot()` returns the root an `AgentSession` resolved;
  doc/LIB_API.md shows the write and resume paths.
- Release and reopen PRs no longer re-run the full CI. A `Release fast path`
  job (`scripts/release_fast_path.py`) checks that the PR's merge commit adds
  only what `scripts/release_cut.py` generates from its base, regenerated in a
  scratch worktree and compared byte for byte, and that the base's push run of
  CI on `main` succeeded (waiting up to 45 minutes for one still in progress).
  Then the four required checks report success without the suites; the
  version state gate still runs. Any other change, a red or missing base run,
  or an error in the check itself takes the full path.
- The Jev `recall_evidence` surface is retired: `KgRecall` no longer consults
  the System-One judge. It appended each hit's relevance percent, an
  evidence-sufficiency score and usage guidance, which in the paid
  attribution pilot cancelled the recall gate's gain in gold evidence the
  model opened (34/60 against 42/60 for the gate alone). A redesign that
  only reordered rows inside the gate's BM25 band put gold first more often
  offline (LongMemEval-S turn-level holdout 272 of 288 against 258,
  p = 0.0005) but showed no gain in a paid paired pilot on 139 cases (gold
  memory opened 56 against 53 of 125 pairs, p = 0.72, after a post hoc
  re-validation; the pre-registered analysis was voided because reordering
  breaks the merge order the evaluator checks), so it was removed too.
  Configuration that still names `recall_evidence` keeps working: the name is
  skipped with a warning and the other surfaces stay advised; a list naming
  only it is refused like an empty list. Records:
  `evals/memory/pilots/longmem-recall-order-glm52-v1` and
  doc/JEV_SYSTEM_ONE.md §6.4-§6.5.

### Removed

- Plan mode. `PermissionMode.plan`, the `EnterPlanMode`/`ExitPlanMode` tools,
  the `<proposed_plan>` protocol and the per-session plan file under
  `<state root>/plans/` are gone, and so is the `plan_approval` UI request:
  `UiRequest`/`UiResponse`, `protocol.wire` (not yet released) and the `--web`
  page no longer carry it. `--permission plan`, `/mode plan` and an agent file
  with `permissionMode: plan` are now rejected as unknown values instead of
  selecting a read-only mode; Shift+Tab cycles default ↔ acceptEdits. The
  built-in Explore and Plan subagents are read-only by their tool allowlists
  (Read/Grep/Glob, plus KgRecall/KgContext for Plan), which also cap dispatch,
  instead of by a permission mode; Explore loses Bash, which plan mode denied
  unless a settings allow rule matched. The AgentCore ABI never exposed plan mode; its
  checkpoint byte 2 stays reserved and decodes as corrupt. Breaking for
  source-level embedders that name `.plan` or `.plan_approval`. A plan
  approved through ExitPlanMode was the only producer of a TinyKG plan graph
  (`kg/plan_commit.zig`), which has no production caller now; existing
  `kg_root` pointers are still read.

### Fixed

- **AgentCore restore reported `degraded` with nothing lost** (issue #334).
  Restoring a checkpoint without Session permission rules under a different
  policy fingerprint (a newly selected Host Tool, another mode) reported
  `degraded` with zero invalidations and no issue. The official SDK rejects
  that summary with `InvalidPayload`, so restore and `describe` failed for
  SDK Hosts. Health is now `degraded` exactly when a Skill, Permission or MCP
  grant was invalidated; the policy generation still advances and the new
  tool still asks for approval. A checkpoint whose Skill selection enabled
  nothing had the same fault when the catalog was unavailable or changed. The
  ABI revision and the checkpoint format are unchanged.
- **TUI: a resize while a reply streams** (issue #325). The generation region
  no longer restores the cursor to a half-line column measured before the
  resize (a reflowing terminal has moved that text): the continuation is
  dropped and the line sealed. The region is redrawn at the new width, also
  when the resize happened while an overlay was open.
- **TUI: stopped and continued** (issue #326). After SIGSTOP/SIGTSTP and
  `fg`, the next input poll re-enters raw mode and re-sends the Kitty
  keyboard / modifyOtherKeys and bracketed-paste enables, so input typed
  after a shell left the terminal in canonical mode reaches the prompt. A
  read interrupted by the resume no longer ends a permission or question
  dialog or the pager.
- Python and Node SDK packages (from #315), before their first publication:
  - **Python `Session.close()` lost the handle when the destroy failed.**
    Leaving a `with` block during a `stream()` the loop stopped with `break`
    returned BUSY, dropped the handle, made `abort()` a no-op and leaked both
    the Session and the Runtime. `close()` now aborts a run that is still
    going and waits for it (`close(timeout=…)` raises TimeoutError and
    keeps the Session open), and keeps the handle (and the Runtime's)
    whenever AgentCore refuses. Called from one of that Session's own
    callbacks, it raises RuntimeError instead of deadlocking; closing another
    Session from a callback still works.
  - **Node: a tool result `JSON.stringify` cannot encode crashed the host.**
    A BigInt, a cycle or a function raised an unhandled rejection that exited
    the process, or, with an `unhandledRejection` handler installed, left
    AgentCore waiting forever. It is now a model-visible tool error. An
    `onUiRequest` answer that cannot be encoded is not answered, and the run
    rejects with the error. A rejection value with no string form, such as
    `Object.create(null)`, still answers the call.
  - **Node** names status codes 11–25 and 27 instead of `STATUS_ERROR`.
  - **L2 tests against the real library** for `submit`, `abort`,
    `close()` during a run, allow and deny rules, `set_permission_mode`,
    `allow_session` (asked once per file target), `ask_question` answers and
    the OpenAI Chat Completions provider, in both packages.
    `scripts/tests/test_sdk_package_versions.py` checks the package versions
    against `sdk/VERSION`.
  - **CI:** the `SDK bindings` jobs report under their names on every run
    and skip their steps on a docs or eval scope (doc/CI_DESIGN.md §1).
  - **README:** the gateway row is the 2026-10-16 Windows 11 ReleaseFast run.
    At 64 clients the overhead is 3 ms p50 / 9 ms p99; "1–3 ms" was the
    8-client row. The release unit row cites the 0.5.0 assets. The Code
    column no longer bolds a score that is not the highest.
- Configuration written wrong is reported instead of silently ineffective.
  Loading is unchanged - the broken piece is still skipped - but a malformed
  hook never fails, it just never fires, and until now each case left only a
  `warn` log line below the default log level.
  - **Hooks.** The new `/hooks` lists the hooks in effect per event and every
    problem the last load found, with its file and JSON path: a settings file
    that is not JSON, `hooks` that is not an object, a Claude Code event
    metacodes does not run (`SessionStart`, `UserPromptSubmit`, ...), a key
    that is no event at all (`PostToolUSE`, with a suggestion), an entry or
    hook of the wrong shape, a `type` other than `command`, a missing
    `command`, a `timeout` that is not a positive number or exceeds 600 s,
    and hooks written in `.claude/settings.local.json` or a `--settings`
    file, which metacodes does not read hooks from.
  - **Skills.** `/skills` lists each Skill whose `SKILL.md` has no
    `description`: listings show its first body line (Claude Code's
    fallback) or nothing, and the model picks Skills by that line.
  - **Agents.** `/agents` lists agents without a `description` (the Task tool
    lists them with nothing) and agent files that did not load, with the
    reason.
  - The startup banner and `/doctor` count these and name the command that
    lists them (`config issues: 2 hooks, 1 skill · see /hooks /skills`).
- `ToolSearch` misses no longer read as "the core tools are missing"
  (issue #287). A miss says that ToolSearch only searches deferred tools,
  names the loaded tools whose names match the query's keywords (`file read
  write edit bash` points at Read, Write, Edit and Bash), and lists the other
  loaded tools and the deferred ones still to fetch. It answers from the
  turn's own request (`ToolContext.request_tools`: the tools array and the
  deferred catalog `agent_loop` built), so it never calls a tool the request
  left out callable - team tools without `--agent-teams`, tools outside the
  active Skill's pool, WebSearch on a provider that cannot search - and
  `select:` no longer hands out such a tool's schema.
- `SessionHost`: an interrupt or close of a Run waiting on a UI prompt could
  fail to stop it. The prompt was released before the kernel abort was
  requested, so the Run took the cancelled prompt as a denied tool, sent its
  next request, and - against a fast provider - ended normally first; the
  interrupt then reported `too_late` (seen once on Windows CI). The abort is
  now in force before the prompt is released; an answer racing the
  interrupt is still discarded.
- MiniMax-M3 takes image input: the model table now says so (MiniMax's
  OpenAI-compatible Chat Completions documentation lists image understanding
  for M3), so AgentCore and the CLI no longer refuse its images (issue #273).
- `AgentSession.setModel` rebuilt the provider without the Session's
  `auth_scheme`, so a route authenticated with `x-api-key` or a custom header
  fell back to `authorization: Bearer` after a model switch.
- doc/API.md said images are never replaced with placeholder text while a
  later paragraph documents the placeholder for image tool results; the first
  statement now covers images in user input only.

- `metacodes sealed serve` stops cleanly. Ctrl+C (SIGINT; also SIGTERM and
  SIGHUP, or the console closing on Windows) now only raises the process-wide
  shutdown flag, and the main thread stops the HTTP server, joins its accept
  loop, frees the Gateway and exits 0 within a 50 ms poll tick. Before,
  `serve` slept forever and looked at no signal, so the console's default
  handler was all that ended it; on Windows that handler runs on its own
  thread while the accept loop is still running, and a gateway left behind
  this way kept `zig-out/bin/metacodes.exe` and its port. A second `serve`
  on a port in use is refused with `BindFailed` rather than sharing it
  (`platform/net.zig` binds with SO_EXCLUSIVEADDRUSE on Windows and
  SO_REUSEADDR elsewhere, neither of which admits a second listener); a
  platform test and an L2 now assert it.
- A provider stream that ends before it reports how it stopped is no longer
  taken for a finished answer (issue #269). A clean end of the connection, or a
  bare `[DONE]`, without Anthropic's `message_delta.stop_reason`, OpenAI chat's
  `finish_reason`, the Responses `response.completed`/`response.incomplete`
  event or Gemini's `finishReason` used to come back as `end_turn`; when the
  lost bytes were the ones carrying `max_tokens`/`length`, a truncated answer
  read as complete and the continuation that should have followed never ran.
  Such a stream is now a mid-stream failure: its text is discarded and the turn
  re-issued within `max_stream_turn_retries` (two in headless mode), and with
  none left the Run ends in `api_error`. A stream that reported its stop and
  lost only the frame tail after it (`message_stop`, `[DONE]`, a trailing usage
  chunk) still finishes normally, and its stop — `max_tokens` included — still
  drives the continuation; a frame tail without a stop report before it is
  incomplete. An Anthropic tool_use block still open when the stream ends was
  silently dropped and now makes the stream incomplete. Gemini's stop report is
  read from the candidate and `promptFeedback` themselves, so a `finishReason`
  key inside a function call's arguments no longer passes for one. An empty
  200 body is incomplete too, rather than an empty answer. Gemini
  `CONTINUATION` (the answer reached the per-request limit but is not finished)
  now drives the same continuation as `max_tokens`.
- `WebSearch` no longer passes off a search the server paused as a complete
  one. Its internal search request is the only one that carries a server tool,
  and when Anthropic stops it with `pause_turn` (the server-side search loop
  reached its iteration limit) the result now starts with a note that it may
  be incomplete; with nothing returned yet it fails as `WebSearchIncomplete`
  rather than saying "No search results found". The search is not resumed:
  resuming means sending the paused response back verbatim, server blocks
  included, which this request does not keep. The agent loop's own requests
  carry no server tools (see the `agent_loop.run` change above), so they
  never end in `pause_turn`.
- OpenAI Chat Completions streams no longer drop text (issue #258). metacodes
  always asks for `stream_options.include_usage`, under which every ordinary
  chunk carries `"usage": null`; the parser took any chunk containing the key
  `usage` for the usage report and returned before reading the rest, so the
  chunk's text, reasoning, tool-call deltas and `finish_reason` were lost. A
  Host or AgentCore SDK consumer could receive no text at all, tool calls never
  formed, and the stop reason came back unknown. Usage now counts only when its
  value is an object (at the top level, or inside a choice where some
  compatible endpoints put it), its numbers are read from that object alone,
  and a chunk that carries both content and a usage object yields both,
  content first. The Responses API and Gemini paths had the same presence test:
  a `null` `response.usage` or `usageMetadata` was reported as a measured zero,
  and Responses read token counts from the whole terminal event, where an
  echoed tool schema with an `input_tokens` property could supply them. Both
  now read only the usage object and report nothing when there is none.
- The daemon end-to-end tests (`tests/e2e/daemon_serve_e2e.sh`,
  `daemon_serve_multi_e2e.sh`) run again and now run in `zig build test` on
  POSIX hosts. They still sent `/mode plan`, which no longer exists, and
  used fixed ports; they now use `/mode dont-ask`, kernel-picked ports, an
  isolated state root with TinyKG autostart off, and also cover `/health`, the
  token, an IPv6 bind and the non-loopback refusal.
- **SIGPIPE no longer interrupts blocking calls with EINTR.**
  - **Cause:** `metacodes` ignores SIGPIPE at startup, but every `std.Io.Threaded.init` swapped that for a do-nothing handler installed without SA_RESTART. Its `deinit` put back whatever it had found, so overlapping lifetimes could leave another instance's handler in place.
  - **Effect:** a handler, unlike SIG_IGN, gets the signal delivered. On macOS a write to a closed socket signals the whole process, so any thread's blocked `recv`/`poll`/`accept`/`waitpid` could return EINTR:
    - the web server reads `recv <= 0` as the end of a request and dropped it;
    - the TinyKG autostart probe once took it for "no answer".
  - **Fix:** every `std.Io.Threaded` is now created through `platform.signal.threadedIo`, which keeps SIGPIPE ignored when the process asked for it, and in tests. A library embedded by a host keeps std's behavior; the host owns its signal policy.
  - **Children:** they get the default SIGPIPE back before `execve`. An ignored disposition survives exec, and without the reset a child pipeline such as `yes | head` would see EPIPE errors instead of ending normally.
  - **Enforcement:** `zig build test` fails on a direct `std.Io.Threaded.init` call (`test:io-threaded`).
- `/mode` could switch a session into a permission mode its settings disable
  (`disableBypassPermissionsMode`, `disableAutoMode`): they were enforced only
  when the settings were loaded. `/mode` now refuses such a mode on every
  surface (terminal, `--web`/`serve` `POST /command`), leaving the mode
  unchanged, and a `--web`/`serve` message asking for it is refused with
  `message_rejected` before anything else in it is applied.
- Work could still run under a permission mode the settings disable
  (`disableBypassPermissionsMode`, `disableAutoMode`) without passing a mode
  switch: an AgentDef's `permissionMode` (Task subagents, background jobs,
  in-process teammates) and a forked Skill bound to such an agent applied it
  as is, so a project `.claude/agents/x.md` with `permissionMode:
  bypassPermissions` ran a subagent in bypass. Such a spawn now runs as
  `default`, logs a warning and says so in its result
  (`permission_mode_notice` on the Task result; a leading line on the forked
  Skill's result; `/agents` marks the mode). Every permission decision now
  runs under `default` when the mode on its context is disabled, whatever
  put it there, including the ApplyPatch path gate and the AgentCore
  external-Tool fallback. `AgentSession.setPermissionMode` and AgentCore
  `update_permission_mode` refuse such a mode with
  `error.PermissionModeDisabled` / `INVALID_ARGUMENT`; an AgentCore Session's
  settings are the Host-imported rules, which cannot disable a mode, so
  today the Host owns which modes it offers.
- `zig build eval:rule-author-build` and `eval:project-rule-mac-pilot` build
  again. Both had stopped compiling on 2026-10-01, when the state root became
  an explicit parameter. The rule-author probe passes no state root, so a
  missing `METACODES_API_KEY_FD` fails it instead of a stored login paying.
  The pilot's simulated TinyKG daemon was also stale against the client: it
  reported store format 2 instead of 3, and lacked the `set-node-property`
  project binding that snapshots need since 2026-08-18. It now reads the
  expected versions from `src/kg/client.zig` and checks the binding before
  serving a snapshot. `zig build test` compiles both drivers on POSIX hosts
  and runs the zero-paid pilot on macOS.
- **The production release gate's calibration can no longer go stale silently.**
  - **What went wrong:** `cli.py gate --thresholds evals/gates/default.json` had refused every release since the evaluation contract moved to v4 (2026-08-23). Its calibration still named contract v3 and a release-contract fingerprint that suite repins had since changed. CI stayed green because every gate test repaired the calibration before using it.
  - **What changed:**
    - A calibration is now either `production` and current, or `stale` with a `stale_reason` that the gate prints when it refuses.
    - `test_checked_in_calibration_is_current_or_marked_stale` checks the committed calibration, using `release_calibration_drift`.
    - The release contract now names glm-5.3-flash.
  - **Recalibrated for contract v4:** 0.5.0 against the candidate, both suites × 6 trials, 132 rollouts (US$27.51). All nine checks pass with unchanged thresholds. The candidate is 100% trustworthy against 0.5.0's 89%, US$0.009 cheaper and 3.6 s faster per rollout. The calibration records the four rollout files' SHA-256; the rollouts themselves stay out of Git.
- The AgentDef release suite no longer fails `42_agentdef_isolation` on how
  the model spells a fact. Its "modified worktree is kept" check looked for
  the literal `worktree_kept=true` in the model's proof file, so a model that
  copied the same Task result as `worktree_kept: true` failed: 7 of 12
  rollouts in a 2026-10-14 paired run, while in all 12 the worktree was kept,
  held the subagent's file and nothing leaked. The check is now the validator
  `evals/validators/42_agentdef_isolation.py`, which grades the Task tool's own
  structured result and the kept worktree on disk (grader
  `agentdef-release-v2`); the suite fingerprint is repinned.
- Sockets no longer leak into child processes. The `--web`, OAuth callback
  and UDS daemon listeners, and every connection they accepted, were
  inheritable, so each later Bash command, hook, MCP server or browser launch
  took them along. A process that outlived metacodes (a job left running
  after a crash, or one started with `nohup … &`) kept the `--web` port
  bound, so the next `--web` on it failed to bind, and kept the browser's
  event stream open after metacodes closed it, so the page never saw it end.
  Every socket the platform layer creates, the TinyKG service's included, is
  now close-on-exec from creation (Linux `SOCK_CLOEXEC` and `accept4`; on
  macOS `fcntl` under the fork serial lock, and straight after `accept`) and
  non-inheritable on Windows.
- A stdio MCP server no longer outlives a metacodes that crashed or was
  killed. The pipe ends metacodes keeps were inheritable, so every process it
  spawned afterwards, above all the TinyKG service that stays up between
  sessions, held the server's stdin open and the server never saw end-of-file
  (on `main` too). Every pipe the process layer creates is now close-on-exec.
  The same fix stops a permission hook, formal kernel or plugin call that is
  fed on stdin from waiting behind an unrelated child spawned at that moment,
  and keeps each MCP server's log from being held open by the other servers.
- Tests and evaluation harnesses that run metacodes under a throwaway HOME no
  longer pick up the caller's Codex setup. `CODEX_HOME` is an absolute path
  that the throwaway HOME does not move, so with it exported every App a test
  built loaded the caller's Codex Skills and started the MCP servers in its
  `config.toml`, and the tests still passed (one App-building test run directly
  started a probe server 14 times). `zig build` now removes it from every step
  it runs, and `tests/e2e/lib.sh`, the TTY driver, the session-memory and
  runtime-arm smokes, the memory-agent runtime's scripted arms, and the plugin
  gate and pair runner drop it from the child environment themselves.
- Skills that Claude Code and Codex load no longer vanish: a symlinked Skill
  directory or skills root (one unreadable root used to empty the whole
  catalog), YAML frontmatter with folded or multi-line descriptions, block
  lists, quotes or CRLF, non-ASCII names, and Skills carrying a virtualenv or
  large assets (which exceeded the snapshot limits). `disable-model-invocation`
  Skills are no longer listed to the model.
- MCP stdio servers started with an empty environment and without a `PATH`
  lookup, so `npx`, `uvx` or `python3` commands never ran; an unresponsive
  server blocked startup forever; a server `ping` got `method_not_found`; tool
  names with `.` broke provider requests; failures were visible only with
  `METACODES_LOG=warn`.
- A `--web` client that reconnects after the host restarted gets the new
  session's events instead of silence. Event sequence numbers restart at 0
  with every journal, and a cursor from the previous one (`since=41`) made the
  server wait until the new journal reached 41, dropping everything before.
  Each journal now has an epoch: SSE ids are `<epoch>-<seq>`, `/state`
  reports `epoch` next to `seq`, and a cursor from another epoch, one naming
  a position without an epoch, or one past the journal's end is answered with
  `event: resync`
  (`{"reason":"epoch_changed"|"epoch_unknown"|"cursor_ahead","epoch","from"}`)
  and a replay from the oldest kept event. Evictions report
  `"reason":"evicted"`. The bundled page reconnects with `?since=&epoch=` and
  starts its view over (DOM and render state) on a resync. Clients that send
  `?since=N` without the epoch now get a replay instead of a continuation.
- An embedded `AgentSession` keeps "allow always" in the Session. Answering
  a Host permission prompt with `allow_always` also appended a whole-tool
  grant to `<workspace>/.claude/settings.local.json`, a file no AgentSession
  reads but the next CLI started in that workspace does, so one click in a
  web or cloud UI became a lasting grant for every later CLI session there.
  `PermissionContext.always_allow` now defaults to `session`; only the App
  (CLI, TUI, `--web`) opts into `settings_file`.
- EnterWorktree moves the session into the worktree, not just the process.
  It used to chdir and record the entry while the session's working root
  stayed put, so Bash (and every tool working from that root) kept running
  in the original checkout for the rest of the session while relative file
  paths followed the process: two trees at once. Now the root moves with it:
  every later tool call in the same Run starts from the worktree, the next
  Run's options and system prompt name it, the permission working-directory
  check covers it, and ExitWorktree brings all of it back. A tool call after
  EnterWorktree or ExitWorktree in the same response is no longer started
  ahead of it by the stream prefetch. The worktree stack lived in the
  EnterWorktree call's scratch memory, so ExitWorktree read freed memory and
  quitting freed it a second time (a crash in debug builds); it is the
  session's own now. EnterWorktree and ExitWorktree refuse before touching
  git or the directory when the host cannot track a worktree (a subagent, or
  a session moved to the background with Ctrl+B, which shares the process
  with the foreground), and a failed step puts the directory back. With the
  sandbox on, a command in a linked worktree may write the main repository's
  `.git`, so `git commit` works there. Project settings are not reloaded
  from the worktree.
- The installer no longer downgrades an install silently. `scripts/install.sh`
  passes `--upgrade` on every run and fetches whatever GitHub labels the latest
  release, and `metacodes install --upgrade` replaced any other version, so a
  rerun moved an install backwards whenever that label pointed at an older
  version. An older unit now replaces a newer install only with
  `--allow-downgrade` (`install.sh --allow-downgrade`, `install.ps1
  -AllowDowngrade`) or `--force`, and an allowed downgrade says so. The unit
  being installed makes the check; for a release up to 0.5.0, which predates
  it, `install.sh` and `install.ps1` make the same check before running the
  unit, in the same version order, and pass `--allow-downgrade` only to a unit
  that knows it. Only running such an older unit's `bin/metacodes install
  --upgrade` by hand still replaces a newer install.
- A launcher name held by another metacodes install is reported as such:
  `install failed (LinkOwnedByAnotherInstall)` names that launcher's install
  prefix and version, and says how to update it, install side by side or take
  the name over. Before, a release install over a development install's
  `metacodes` launcher failed with a bare "the launcher name is taken". This
  install's own launcher in an older form is now replaced instead of refused.
- `zig build test` no longer leaves TinyKG services running. A session that
  needs TinyKG starts its install's service, which outlives the session on
  purpose, and three test entry points ran the real binary in a throwaway
  HOME: the native REPL tests, the headless protocol smoke and the memory
  runtime smoke's HTTPS environment regression (macOS only). Each run left
  `metacodes --state-dir <deleted temp dir> kgd` processes and their
  `tinykgd` children behind, six pairs per run on macOS (a developer machine
  had 148). Those tests now set `METACODES_KG_AUTOSTART=0` and fail if a
  service is still running under their temporary directory
  (`scripts/eval/kgd_processes.py`), and every e2e scenario run through
  `tests/e2e/lib.sh` stops the service its fake HOME started once the session
  ends, leaving other state roots' services alone. Both recognise a service
  started with `--config <path>` (a `METACODES_KG_CONFIG` file) as well.
- A TinyKG service of another state root no longer locks an install out of
  its own. Every state root used to provision port 8799, so while one
  install's service was down a test run in a temporary home could provision
  and bind the very port that install's `daemon.json` pins, and its sessions
  then met a service that refused their key: `auth_failed` until that service
  was killed (seen for two days on a developer machine). A new configuration
  now prefers a port derived from its own path (20000-32767) and takes a free
  one when that is held. Autostart asks the configured port for readiness
  with the install's key and never takes a service that refuses it for the
  install's own: the default configuration moves to a free port with a new
  key (the old one was presented to that service; any local user can bind a
  loopback port) and the same store, and starts its service there, while a
  `METACODES_KG_CONFIG`
  file is left as written and the conflict is logged. A session whose
  readiness probe meets such a service now asks the host to do that, and the
  `auth_failed` hint in `doctor` names the cause.
- Paid memory evaluations: the runner's loopback proxy for a Jev arm's judge
  now reaches the judge directly, as the CLI does. It honoured `HTTP(S)_PROXY`
  and the macOS system proxy, so behind a proxy that could not reach the judge
  an unreachable judge was recorded as the proxy's 503 instead of 502, and a
  proxy that could reach it measured a path the CLI never takes.
- The port-ownership probe from the previous entry retries a call a signal
  interrupted. A session's process runs `std.Io` threads whose signals make a
  blocked `recv` return `EINTR`; the probe read that as "no answer", judged a
  squatting service "unknown" and left the install behind it (about one in
  forty runs of its component test under load, and once on macOS CI). It now
  retries interrupted connects, sends and reads within its 2 s, and on POSIX
  no longer opens and closes a connection before the request. A TinyKG
  service that fails to start after `tinykgd` has answered no longer leaks
  the bridge's read buffer: the supervisor stopped the copy it moved from.
- The TinyKG startup/resume smoke (`tests/e2e/process_dag_resume_smoke.sh`)
  works again and runs in `zig build test` on POSIX hosts. It still seeded
  tasks into the store the command-line transport uses, which sessions stopped
  reading when the local service became their path, so it failed before its
  check on every run and left a `kgd` behind. It now starts the state root's
  service itself (`kg install` + `kgd`), seeds through the service's
  `/api/run` (`tests/e2e/kgd_api.py`), runs the sessions with autostart off and
  every `METACODES_KG_*` override removed, stops the service on exit and fails
  if any TinyKG process is left.

## 0.5.0 — 2026-10-11

### Added

- AgentCore ABI v1 revision 19 (#236): `session_control->update_permission_mode`
  changes an existing Session's permission mode in place while it is idle.
  The handle, logical Session ID and Conversation stay; there is no export,
  destroy and restore. The first permission decision after the call uses the
  new mode. A change starts a new policy generation and revokes every Session
  grant (`allow_session` and `deny_session`), as a rule update does; setting
  the current mode changes nothing. A Run (including one suspended in a
  Permission callback), compaction, checkpoint export, another mutation or a
  draining Provider cancel makes it return `BUSY`; a poisoned Session returns
  `INVALID_STATE` and an unknown code `INVALID_ARGUMENT`; none of them changes
  mode, generation or grants. `describe` reports `permission_mode` beside
  `policy_generation`, and the policy fingerprint after a change is the one a
  Session created with the new mode would have, so an export holds no revoked
  grant and a restore under the same mode keeps the generation. The Session
  Control table grows by one slot to 80 bytes; the header, Zig and Rust SDKs
  (`raw.rs` regenerated), both source-free consumers, the bundle manifest
  and the docs move to revision 19, SDK package `0.6.0-dev`.

## 0.4.0 — 2026-10-10

### Added

- Stall gate: a run whose tool rounds keep returning nothing new is stopped
  with the new stop reason `stalled` and handed back to the person, instead
  of looping until `max_turns`. A round is stale when every slot that ran
  either failed or returned an answer the model has already seen. Answers are
  keyed by tool and result bytes, without the host's own counters
  (BashOutput's `waited_ms`, and the poll guard's `low_yield_polls` and
  `min_wait_ms`, which change on every guarded poll of a silent job); a
  realized file change is keyed by its action. Remembered answers follow the
  model's view, so a result cleared by compaction or microcompaction counts as
  new when fetched again. The run stops after 8 consecutive stale rounds, or
  after 4 stale rounds in which one identical call was made 4 times. A round
  that brings anything new resets the stretch. The round's results are
  committed first, and nothing is injected into the conversation. The REPL
  names the cause, the repeated call and how to continue. Headless reports
  `"stop_reason":"stalled"` (exit 0) and prints the same notice on stderr.
  AgentCore v1 reports it as `tool_loop`. The REPL and web sessions enforce
  it by default (`--no-stall-gate` turns it off); print mode only with
  `--stall-gate`; `--stall-gate-observe` only records. Each armed run writes
  one `stall_gate` tool-observation record (`metacodes-stall-gate-v1`). The
  policy is proven in `control-plane/lean/MetaCodesControl/StallGate.lean`
  (propext only): decisions bounded over any trace, no decision after a
  round with a new answer or when every round brings a never-seen one, and
  a long enough stale stretch always decides exactly once. Design note:
  [doc/STALL_GATE_DESIGN.md](doc/STALL_GATE_DESIGN.md).
- Host check gate (`--host-check <cmd>` with `--check-gate` or
  `--check-gate-observe`, budget `--check-gate-max <n>`, 1–8, default 3). When
  the model ends its turn after changing the workspace, the host runs the
  pinned check command itself and turns the result into a verdict: passed,
  failed, tainted (the run changed the program the check executes or a test
  file a result names, or the check passed while tests that existed before the
  run are weakened — read from the test-integrity sensor below, so appending
  tests no longer taints a pass — or a file tool changed an existing test file
  that git ignores) or unavailable (spawn failure, 180 s timeout, or exit
  126/127).
  In enforce mode a clean failure continues the same conversation with the
  verdict — failing names and reasons from the JUnit/pytest codecs, and the
  output tail — plus an escalating reading from the cognitive-mode schedule,
  until the check passes or the budget is spent; a turn with no new change is
  never checked, so a question-and-answer turn never runs the suite. Observe
  mode runs the same checks and only records them. Each run with the gate
  armed writes one `check_gate` tool-observation record
  (`metacodes-check-gate-v1`: checks, continuations, final verdict, whether
  changes after the last check went unchecked, the command's SHA-256). The
  policy — clean boundaries never checked, only a clean failure continues,
  observe never continues, continuations within budget, Stop-hook blocks
  within theirs, and at most one check per continuation of either kind plus
  one over any trace — is proven in
  `control-plane/lean/MetaCodesControl/CheckGate.lean` (propext only). The
  continuation budget is separate from the host-injection meter: it is driven
  by a verdict, not advice. Headless and the primary REPL run honour the
  flags; macro runs and embedders do not.
- Test integrity obligation (`--test-integrity`, or `--test-integrity-observe`
  to record only). Tests that existed when a run started are the user's
  record of behavior that callers rely on. At run start the host records the
  commit `HEAD` and the content of every test-suite file that is already
  modified or untracked (it writes nothing to the repository); when the model
  ends its turn after using a tool, it compares every suite file below the
  working directory with that baseline, ignoring whitespace and line order. A
  test case file is weakened when an existing non-blank, non-import,
  non-comment line is gone or a skip/xfail/only marker was added — appending
  tests is fine; any change to another suite file (`conftest.py`, runners,
  data under `tests/`) and any deletion is weakening. The sensor reads the
  workspace, not tool events, so Bash edits, subagents and commits are all
  seen, and restoring the lines disarms it. In enforce mode the first stop
  with weakened tests earns one message that names the files and the removed
  lines and asks the model to restore them unless the request explicitly
  requires the change, in which case it must quote that sentence in its final
  answer. Either way the host reports the end state to the user: a `⚠` line
  after the REPL run, a stderr line in headless text mode, a `test_integrity`
  object in `--json` output. Each armed run writes one `test_integrity`
  tool-observation record (`metacodes-test-integrity-v1`: outcome
  `clean`/`restored`/`kept_cited`/`kept_silent`/`observed`, counts only, no
  paths). The policy — pristine tests never messaged, observe never messages,
  at most one message per run, and composed with the check gate the check
  still runs at most budget + 5 + 1 times — is proven in
  `control-plane/lean/MetaCodesControl/TestIntegrity.lean` (propext only).
  The budget sits outside the host-injection meter, so advisory nudges cannot
  use it up. Headless and the primary REPL run honour the flags; macro runs
  and embedders do not.
- Stop hooks can keep the run going, with Claude Code semantics: exit code 2
  or stdout `{"decision":"block","reason":…}` appends
  `Stop hook feedback:\n<reason>` (the reason defaults to the exit-2 stderr)
  and continues instead of finishing; the hook's stdin carries
  `stop_hook_active`, true once a Stop hook has already sent this run back.
  The host caps this at 5 continuations per run (`stop_blocks_bounded`), where
  Claude Code leaves it to the script. Any hook command can now set
  `"timeout": <seconds>` (capped at 600), and the event budget widens to the
  sum of its commands' timeouts, so a Stop hook can run a test suite.

### Fixed

- On Windows, a session that has to start the TinyKG service no longer waits
  30 s before it renders. Autostart checks that the service is up by
  connecting and closing at once. WSAPoll reports that close as POLLHUP
  without POLLRDNORM, and the socket readiness check looked only at
  POLLRDNORM, so the single-threaded service kept polling the closed
  connection until its 30 s request deadline. A fresh install's first
  session, or the first one after a reboot, took over 30 s to show its
  prompt; it now takes a few seconds. The readiness check now treats a hang-up
  or error as readable, as the writability check already did. The TTY
  harness also no longer starts a TinyKG service in the temporary home of
  each case. Each one outlived its case, and on Windows the leftover service
  kept the home from being deleted.
- On Windows, a session that has to start the TinyKG service now shows its
  prompt in about 0.35 s instead of about 6.7 s. Windows does not refuse a
  connection to a loopback port nobody listens on at once: it resends the SYN
  and gives up after about 2 s. The session paid that three times before it
  started the service: twice for the `store-info` read, which is retried,
  and once more for the autostart check. Both now read the kernel's TCP
  listener table instead of connecting, so when nothing listens the service
  is started right away, and the readiness checks while it comes up cost
  nothing. A running service is never handed an empty probe connection,
  including a service left running by an older release. On other platforms a
  refused connection already returns at once, and the checks still connect
  there.
- An AgentCore session no longer poisons itself when a compact or Run is
  aborted from another thread. The aborted operation could return while the
  abort was still inside `Provider.cancel`; Core answers BUSY to everything
  until that call returns, so the facade's terminal usage measurement failed
  and poisoned the session (the Linux 0.3.1 release job hit it in
  `agentcore_abi_test`). A compact's borrowed provider, which lives on the
  facade's stack, could also go out of scope while `cancel` still used it.
  The facade now waits for in-flight cancels to drain before terminal
  bookkeeping and before returning from a compact.
- The release cut (`scripts/release_cut.py`) runs on a Chinese Windows
  without `PYTHONUTF8=1`. It decoded git's UTF-8 output with the locale's
  GBK codec. On Windows the decode error is raised in subprocess's reader
  thread and only printed, so the commit list came back `None` and the cut
  crashed. It now decodes git, gh and Python children as UTF-8. Characters
  its own output pipe cannot encode, such as `µ` and `✓`, are escaped instead
  of failing the dry run. `scripts/check_version_state.py` read HEAD's commit
  subject the same way and is fixed too.
- The end-of-run host check no longer downgrades verdicts to
  `host_run_tainted` when the run only changed the module under test:
  `verdict.taintedByWorkspaceEdits` matched paths as substrings, so editing
  `semver.py` tainted every result naming `tests/test_semver.py`. Paths now
  match by component (equal, or one ends with `/` plus the other), and
  untracked directories, both ends of a rename and quoted paths count.
- After Ctrl+B the agent tree and the switcher list the main session that
  moved to the background again, and the switcher can stop it (#219). The job
  keeps the session it left, as the session boundary requires, and since
  0.2.0 the tree showed only jobs of the current session, which Ctrl+B had
  just replaced; the prompt promised a tree that could not show the job. The
  new foreground now also shows the sessions it handed off; `/resume` drops
  them, because the resumed conversation is not their successor. Model-facing
  routing (TaskOutput, TaskStop) still sees one session only.
- A model picker opened while a reply streams stays open when the reply ends,
  with its filter, stage, cursor and any sign-in in progress (#220). Each
  phase draws its own region, and the open state went away with the
  generation one. A queued message that starts the next reply keeps it open
  too.
- On Windows, a refused, unreachable or timed-out connection to the model
  endpoint is retried like on the other platforms, and the error says what
  happened (#221). Zig 0.16.0 reports those connect failures on Windows as
  `error.Unexpected`, which ended the request after one attempt as
  `RequestFailed`; request setup now names it `ConnectFailed`. Debug builds no
  longer print std's stack trace for unmapped system errors, which Esc during
  a reply drew over the TUI.
- The offline TTY suite runs in CI on Linux and Windows (#222). It ran
  nowhere, so twelve agent-tree cases had failed since 0.2.0 unnoticed: the
  `/agent-test*` commands created agents that belonged to no session (#218).
  The two TTY backends now end a case the same way, a real-model case skipped
  offline reports a skip instead of a pass, cases delete the directories they
  create, and a binary that does not exit after its terminal closes fails the
  case instead of hanging the run. The replay server those cases use read
  directory entries with the macOS `dirent` layout and found no cassette on
  Linux; it now lists them portably. The TinyKG service end-to-end tests run on
  Windows except the one that needs a POSIX symlink.
- The transcript parser can no longer silently drift from the writer or
  quietly flip persisted flags. `parseMessageLine` now dispatches on the
  `Block` tag (`stringToEnum` + exhaustive `switch`), so adding a block
  variant without a parse arm is a compile error instead of the runtime
  asymmetry that once made every extended-thinking session unresumable
  (`"document"` keeps its distinct `WithdrawnDocumentBlock` rejection). The
  boolean transcript fields — message-level `delivered`, `tool_result`'s
  `is_error`/`delivered` — now reject a present-but-non-boolean value as
  `InvalidTranscript` instead of silently reading it as `false`: a coerced
  flag survives into memory and the next `/retry`/compact full rewrite would
  persist the flipped semantics to disk. An absent field still defaults to
  `false` for older transcripts.

## 0.3.1 — 2026-10-07

### Fixed

- The macOS release build passes the AgentCore gate again. Since bundles ship
  a shared library next to the static archive, Apple ld resolved
  `metask-agentcore-sys`'s `-lmetask_agentcore` to the `.dylib`, so the
  crate's own unit tests linked it dynamically and failed to load it
  (`Library not loaded: @rpath/libmetask_agentcore.dylib`); 0.3.0 was tagged
  but never published because of it. The build script now links the archive
  from a directory that holds only it. Crates depending on the SDK were not
  affected: rustc bundles the archive into their rlib.

## 0.3.0 — 2026-10-07

### Added

- The Jev System-One advisor is configured in the install's
  `<state root>/config.json` (`"jev": {"url", "mode", "timeout_ms", "model",
  "decisions"}`) instead of only the environment; each `METACODES_JEV_*`
  variable still overrides its field, so evaluation harnesses that inject them
  per arm are unchanged. An unknown key, a mistyped value or an invalid
  setting disables the advisor with a warning. `metacodes doctor` reports the
  advisor's state, URL and whether it came from the file, the environment or
  both (never part of `--strict`).
- `metacodes doctor` reads like a report at a terminal: the version, install
  prefix and state root, one line per runtime component (paths relative to
  the install, a digest only when it does not match), the TinyKG service, and
  a closing verdict, in colour unless `NO_COLOR`. A service that a session
  would start shows as not running rather than as a warning. `--plain`, and
  any output that is not a terminal, keep the one-line-per-check form
  scripts parse; `--json` is unchanged. `doctor` now also validates the
  TinyKG staging receipts (`tinykg.provenance.json`, `tinykgd.provenance.json`)
  against the binaries beside them, and a receipt that does not describe its
  binary fails `--strict`; release and install-prefix verification require
  both receipts to be accepted.
- The TinyKG service starts by itself. A CLI session whose readiness probe
  finds the install's service unconfigured or not listening provisions it
  (as `kg install`, on 8799 or a free port when that is taken) and starts
  `metacodes kgd` in the background (own session, log in
  `<state root>/kg/kgd.log`), under a cross-process lock per state root.
  `METACODES_KG_AUTOSTART=0` turns it off; explicit `METACODES_KG_URL`
  services and missing `METACODES_KG_CONFIG` files are left alone; the
  shared `unconfigured`/`daemon_unreachable` repair hints say so. The core
  only exposes `KgClient.Autostart`; the host decides how to start it.
  `kgd` now stops cleanly on SIGTERM/SIGHUP as well.
- Hosts customize the system prompt per Session (#184, phase 2). AgentCore
  ABI v1 moves to **revision 18**: `SessionCreateConfigV1.prompt_profile`
  edits the kernel's named prompt sections — replace `metacodes:identity`,
  add `host:*` sections at any order, replace or remove optional guidance —
  while the safety policy and system rules stay locked and the environment
  facts stay kernel-generated. Replacing the identity also drops the
  sentences that belong to it (the environment product line, the doing-tasks
  framing and help bullets), so the prompt names neither MetaCode nor
  software engineering. An invalid profile is refused whole with a diagnostic
  naming the entry and the rule (locked/generated targets, duplicate or
  malformed ids, limits, strict `{{model}}`/`{{workspace_root}}`/`{{platform}}`
  interpolation). The profile is frozen into the Session and its checkpoints;
  the new `session_control->set_prompt_profile` replaces it while idle, one
  prompt-cache boundary per effective change. Subagent and fork-Skill prompts
  inherit it through the replaceable `metacodes:subagent`. Each Run reports
  its prompt — section ids, orders, origins, classes and digests, and the
  prompt digest — in the journal's `run_started` record, in a new
  `prompt_manifest` observation event when it differs from the previous Run's,
  and in `describe` (`prompt.profile`, `prompt.manifest`).
  `RunOptionsV1.context_blocks` gives one text or multimodal Run volatile Host
  facts as a leading `<system-reminder>` text part of its user record, so they
  extend the cached history instead of moving the system prompt. The Session
  Control table grows to 72 bytes; `SessionCreateConfigV1` and `RunOptionsV1`
  keep their sizes. A checkpoint without a profile keeps the marker-8 envelope
  byte for byte; one with a profile is marker 9 and older libraries refuse it
  as incompatible. Without a profile every prompt is byte-identical to before.
  The source-level Zig API offers the same through
  `SessionConfig.prompt_profile` and `AgentSession.setPromptProfile`. SDK
  package version `0.5.0-dev`.
- `metacodes --dump-prompt --sections` lists the CLI's system prompt section
  by section (id, order, class, origin, size, digest) and checks the joined
  digest against the prompt it built.
- Every AgentCore bundle ships a shared library beside the static one
  (#182): `lib/libmetask_agentcore.so`, `lib/libmetask_agentcore.dylib`, or
  `lib/metask_agentcore.dll`, for Hosts that can only load a library at run
  time (Python `ctypes`, Node FFI, JNA, .NET P/Invoke). It exports only
  `metask_agentcore_get_api` (plus inert toolchain names on PE and Mach-O),
  macOS uses `@rpath/libmetask_agentcore.dylib`, and the manifest pins its
  SHA-256 and records `shared_library` (path, entry point, load name, needed
  libraries read from the image). Bundle assembly refuses a shared library
  with any other export or a dependency a clean OS installation lacks (an
  MSVC DLL may need the Visual C++ runtime, which the manifest lists), and the
  native gate runs the C consumer through `dlopen`/`LoadLibraryEx` with no
  AgentCore link input.

- Installation as isolated, coexisting installs (doc/INSTALL_DESIGN.md).
  `metacodes install --prefix <dir>` copies the release unit it belongs to,
  re-verifies every file against the release manifest, writes
  `<dir>/etc/metacodes/install.json`, creates the install's own state root
  (`<dir>/state`, or `--state-dir`), optionally places the AgentCore SDK under
  `<dir>/sdk/agentcore/` (`--sdk`) and a launcher on PATH (`--link`,
  `--link-name`), and ends with the installed `doctor --strict`. It refuses a
  prefix holding foreign files unless `--force`, and another version unless
  `--upgrade` (or `--force`); replacing a version removes the files the old
  manifest listed and the new one does not, and keeps the state root. A taken
  launcher name is refused before any file is written.
  `scripts/install.sh` (macOS/Linux) and `scripts/install.ps1` (Windows)
  unpack an archive, check its `.sha256`, and call it.
- One-line install and a side-by-side development install:
  `curl -fsSL …/scripts/install.sh | sh` downloads the latest release for the
  host (or `--version`), checks it against the release's SHA256SUMS, installs
  it with its AgentCore SDK, and upgrades in place when rerun.
  `scripts/install.sh --dev` builds the checkout's release unit (kernels,
  pins, `release:verify`, SDK) and installs it with its own state root: the
  main checkout as `metacodes-dev`, a linked worktree as
  `metacodes-dev-<worktree directory>`, so a worktree under test never
  replaces the main checkout's install. `--uninstall` removes an install
  (never one a process still runs from, never a launcher it did not write).
  A release that predates `metacodes install` (manifest v1) is refused
  instead of run. A rerun needs none of the first run's options: the
  installer keeps the state root the install record names unless
  `--state-dir` is given, the script keeps the launcher name that already
  points at the install, and a development install's prefix follows its
  checkout rather than its launcher name.
- The release unit is complete on every platform (manifest schema 2): it
  ships the TinyKG daemon and both Lean governance kernels, built natively on
  each release runner and pinned into the executable, with the licence texts
  of the Lean runtime, GMP and libuv the kernels statically link
  (`vendor/lean-runtime/`, `THIRD_PARTY_NOTICES.md`).
- `zig build kernels:stage` builds both kernels from the checkout into
  `<prefix>/libexec/metacodes`, and `zig build test` uses them whenever a Lean
  toolchain is present, so every kernel-gated test runs with no
  configuration; `-Dlean-kernels=on|off` forces or disables that.
  `scripts/kernel_pins.py` prints the `-D…-kernel-sha256` pins for a staged
  prefix.
- `metacodes doctor` reports the state root, its source and any resolution
  error; `--strict` fails on one.

### Changed

- The CLI consults the Jev System-One advisor by default: with nothing in
  config.json or the environment it uses the team's `metask-jev-4b` at
  `http://58.211.6.133:10420` in `advisory` mode (plain HTTP over the public
  network). `"jev": false` in config.json, or `METACODES_JEV_URL=off`, turns
  it off; library embedders get the default only by setting
  `Config.jev_builtin_default`. The build exports `METACODES_JEV_URL=off` to
  every step, and the memory-agent evaluation harness starts every arm with
  it, so tests and unadvised arms never reach the service. `doctor` reports
  `source=default`.
- The built-in Jev default advises `scoped_recall` only, the configuration
  doc/JEV_SYSTEM_ONE.md §7 recommends: in the paired pilots the `KgRecall`
  annotation cancelled the recall gate's gain in verified evidence (34/60 vs
  42/60), the relation judge was never consulted in any pilot, and the
  enumeration judge never crossed its threshold in 55 consultations while
  each consultation is a synchronous round trip. `"decisions"` in config.json
  (or `METACODES_JEV_DECISIONS`) still selects any subset; a `url` of one's
  own still starts from every surface in `shadow`.
- The system prompt is assembled from named sections (#184, phase 1):
  stable `metacodes:*` ids, sparse orders, and a class per section (identity
  and the tool guidance replaceable, the safety policy and system rules
  locked, tone/efficiency/progress removable, environment/memory/Skills/
  subagents/TinyKG generated). The former intro is now `metacodes:identity`
  plus `metacodes:safety-policy`. Prompts are byte-identical to before; a test
  renders 160 tool-set/Skill/memory/TinyKG/deferred combinations against the
  frozen previous concatenation.
- AgentCore ABI v1 moves to **revision 17** (#173): `allow_session` on a
  built-in `Write` or `Edit` now covers later calls of the same Tool on the
  same file, whatever their content or edit strings, instead of only an
  identical call. The Permission callback's `candidate` gains the scope
  `file_target` and a `target` field naming the canonical file (null for
  `exact_arguments`, which every other eligible Tool keeps). The target is
  derived exactly as the tool derives the file it opens, and only when a
  strict JSON parse agrees with the tool's own argument reading; a grant is
  bound to its Tool and Session and ranks where Session grants always ranked.
  Checkpoints record the scope: an older AgentCore refuses one that holds a
  file grant, and checkpoints without one are unchanged. Layouts, tables and
  status codes are unchanged. Revision 16 is skipped because it named the
  withdrawn PDF input; SDK package version `0.4.0-dev`.
- User state lives under a state root instead of a hard-coded
  `~/.metacodes`: `--state-dir` (first argument to cover subcommands), then
  `METACODES_HOME`, then the install record beside the executable, then
  `~/.metacodes`, which development builds and older installs keep. A broken
  install record or a relative override stops the CLI instead of falling
  back to another install's state. Project-scoped `<project>/.metacodes/` and
  `~/.claude/` are unchanged.
- Embedding API: metacodes-core no longer reads the user's home to find
  state. `ToolContext`, `agent_loop.Options` and the subagent, job and
  teammate snapshots carry `state_root`; `WorkspaceConfig.state_root`
  configures an `AgentSession` (default `<home>/.metacodes`, so AgentCore
  hosts are unchanged); `KgClient.ResolveOptions.home` is now `state_root`;
  `auth`, `provider_oauth.Session.initHome`, `config_store.Store.initHome`,
  `metask_ledger`, `AgentSet.loadFromStandardPathsWithPluginSources`,
  `skills.runtime.catalog.defaultSources` and `context_caps`
  (`configureStateRoot`) take the root explicitly.
- The swarm team-directory removal guard requires a strict
  `<state_root>/teams/` prefix instead of a `/.metacodes/teams/` substring.
- A relative `METACODES_KG_STORE` or config `kg_store` is completed against
  the state root, no longer against `$HOME`: with the default root,
  `kg/my.kg` that meant `~/kg/my.kg` now means `~/.metacodes/kg/my.kg`. Use
  an absolute path to keep a store outside the root.
- Learned context caps (`context_caps.json`) persist only where the host
  configures a state root; the CLI does, embedding hosts now keep them in
  memory unless they call `context_caps.configureStateRoot`.
- An install record wins over `$HOME`: a harness that isolates a run by
  setting `HOME` must also set `METACODES_HOME` (or use a development build)
  when it points at an installed executable.

### Fixed

- A long session no longer keeps every buffer it ever allocated. The
  interactive REPL, headless, web, `serve` and teammate modes ran on the
  process arena, which frees nothing: each request body, streamed response,
  tool result and every growth step of a growing buffer stayed committed
  until exit, about six times the bytes sent to the provider. Multi-day
  sessions reached 14 and 31 GB of committed memory and exhausted the
  system commit limit. Sessions now use the general-purpose allocator
  (`serve --sessions N` included); on a scripted 30-turn session, growth fell
  from 40 MiB to 1.9 MiB. Running on a real allocator surfaced a
  use-after-free in `App.deinit` (it read the freed `App` after destroying
  it), now fixed. `zig build test` runs `scripts/session_memory_smoke.py`
  against both binaries: memory growth must stay below the bytes sent, and
  the Debug binary must exit the REPL with no allocator report.
- Tasks left `in_progress` no longer crowd out the current one. A model that
  opens a task per attempt and never closes the last one piled up stale
  in-progress tasks, and the code took the *first* in-progress task as the
  current one: the compaction task anchor named the oldest three with
  "continue the tasks above" (a long session's anchor revived three
  superseded attempts and left out the one in progress), and `KgRemember`
  attached `derived_from` provenance to the oldest. Both now follow the most
  recently claimed task (a claim sequence kept in the degraded-mode task
  mirror, not a clock: the monotonic clock restarts at boot); the anchor names
  the three most recent and lists older open ids with a request to close the
  ones later work finished or replaced. Closing a task (TaskUpdate completed,
  deleted or failed, TaskStop) now lists the other tasks still in progress in
  its result, oldest claim first, so they are reviewed at the moment one ends.
  Each claim now records who made it and when (the same identity the agent
  uses for TinyKG leases, declared by the agent loop), and the anchor, the
  closing list and provenance leave out work another agent still holds: the
  degraded-mode mirror is shared by every session in the repository and by
  swarm teammates, and the startup rebuild of persistent tasks keeps each
  lease's real holder. In the degraded mirror another agent's claim expires
  after two hours (TinyKG's default lease). Like an expired TinyKG lease, it
  can then be claimed again, and both the anchor and the closing list say so
  separately: they never name it as work to continue or suggest closing it
  directly. Persistent `kg-*` tasks follow TinyKG's own lease. A new process
  gets a new identity unless it resumes the session, so after a plain
  restart (or Ctrl+B) the previous process's claims count as another
  agent's until their lease lapses, just as with TinyKG leases. Rows whose
  claimer is unknown (written before this change) are treated as the
  agent's own, as before. When the task panel overflows it keeps the most
  recently claimed tasks instead of the oldest, and a completed task reloaded
  from the mirror after a reboot no longer stays on the panel indefinitely
  (its timestamp is from the previous boot's clock).
- The WorkBuddy installed-adapter suites run in CI: the Linux and macOS gates
  provision the pinned WorkBuddy-Bench checkout
  (`scripts/eval/workbuddy/provision_checkout.sh`: pinned commit, this
  repository's overlay, `uv sync --frozen`) and `zig build test` inherits
  `METACODES_WORKBUDDY_CHECKOUT`. They had always skipped, and the memory
  continuity test had gone stale behind them: its stub container never wrote
  the export probe verdict the v42 export gate requires, so every trial
  degraded. The native REPL smoke (`test_native_runtime.py`) now gets the
  installed product on POSIX instead of skipping.
- The native project-Harness suites (E3 runtime and templates, E2 evolution,
  the calibration matrix) run in `zig build test` whenever the project kernel
  is built (POSIX); they had skipped everywhere, and three regressions had
  piled up behind them. The lifecycle driver wrote its correction session
  under `<home>` instead of the state root since the per-install state root
  (finalize refused every prepare); its static replay still expected an
  oversized verify-only Write to be blocked, although bounds have been an
  envelope rather than a verdict since August; and both project-Harness
  analyzers stood at formal batch schema v5 while the product emits v6, so
  every real rollout failed as "schema drift" or "mixed legacy/current".
  Both analyzers now keep v5 bindings checked, require v6's `within_root`,
  and are pinned to the Zig emitter by a test.
- `zig build eval:jev-recall-driver` compiles again (it still called the
  runtime's removed `fromEnv`); `zig build test` now compiles it.
- The Jev relation judge for `KgRemember` broke whenever a new memory had two
  or three related ones: `n = @min(len, 3)` was inferred as `u2`, so `2 * n`
  overflowed — a panic in Debug builds, and in the ReleaseSmall executable a
  request with no questions. Only the one-related-memory case worked, which
  may have skewed any evidence gathered on the `memory_relation` surface.
- KgRecall failed after any write in a store holding one node whose text has
  no tokens, and reported "TinyKG daemon 不可达" while the daemon was up. On a
  stale full-text index TinyKG's JSON search refuses such a node
  (`Unsupported`); `kgd` now rebuilds the index before serving a retrieval.
  The daemon's `tinykgd: error: <Name>` stderr is now parsed, so its refusals
  are classified and shown instead of being reported as an unreachable
  daemon, and auto-scoping a custom type (`schema-scope --if-absent`, which
  tinykgd answers without a commit receipt) no longer fences every later
  write of the session as an ambiguous commit.
- `--version` and the release manifest disagreed on whether a tree with an
  untracked file is dirty (the executable ignored untracked files, the
  manifest counted them), so `release:verify`, and with it
  `install.sh --dev`, failed on any checkout holding one. Both now count
  untracked files and ignore ignored ones.
- The macOS Lean kernels linked Homebrew's `libgmp` and `libuv`, so they ran
  only where Homebrew had installed them. Both kernel scripts now link the
  static libraries of the Lean toolchain, and every kernel build ends in
  `scripts/check_kernel_self_contained.py`, which refuses any dependency
  outside the OS.
- The coverage-gap L2 leaked the file-change records `executeOne` returned;
  it only ran against a real project kernel, which no CI job provided.

- A release PR could fail its own CI. The version state gate recognises the
  release PR by its title and its `release` label, and `ci.yml` took the
  labels from the `opened` event. `gh pr create --label` adds the label after
  it creates the PR, so that event can be recorded without it: 0.2.1's was,
  and the PR had to be closed and reopened to get a new event. The gate now
  reads the PR's labels when it runs.

## 0.2.1 — 2026-09-30

### Fixed

- The release automation's first real run (0.2.0) hit two bugs. The cut
  (`scripts/release_cut.py`) put the whole changelog section into the
  release PR body, and GitHub refuses a body over 65,536 characters (0.2.0's
  section was 90,841), so it stopped after pushing the branch and left the
  checkout on it. A body over the limit now points to the section's
  `CHANGELOG.md` diff and shortens the bump-derivation lists with a count;
  the size is checked before anything is pushed, and the checkout always
  ends on `main`. `scripts/release_notes.py` likewise stops notes over
  GitHub's 125,000-character release body at the last whole entry and points
  to the full section. The tag job (`release-tag.yml`) looked the tag up
  through an endpoint that answers 404 when it is missing, and `gh` prints
  that error body on stdout, which read as an existing tag: the job failed
  without tagging, and 0.2.0 was tagged by hand at its merge commit. It now
  uses `git/matching-refs`, which answers an empty list.
- The Linux release build could not compile the AgentCore C consumer
  (`tests/agentcore_artifact_consumer/consumer.c`). It used `PATH_MAX`, which
  glibc declares only under a POSIX feature macro, and the consumer is built
  with `-std=c11`. The step runs only in tag builds (pull requests run the
  AgentCore gate on Windows alone), so 0.2.0's build was the first to reach
  it: 0.2.0 is tagged but was never published, and 0.2.1 is the first release
  that carries its changes. The consumer now falls back to Linux's 4096, as it
  already fell back to `MAX_PATH` on Windows.
- The x86_64 Windows/GNU AgentCore archive could not be linked by MinGW's GNU
  ld, so the Rust bindings' cargo builds failed with undefined references to
  `roundq`. std.json's integer parsing calls it; the bundled compiler_rt
  defines it only weakly, GNU ld does not load an archive member for a weak
  definition, and MinGW's libraries do not provide it. The archive now
  carries a strong `roundq` (`src/agentcore/windows_gnu_crt_shims.c`), a
  support symbol like the MSVC CRT shims. The release job's AgentCore gate
  also gets the five-minute test watchdog the Windows CI already uses: at
  the one-minute default it killed a slow unit test.

## 0.2.0 — 2026-09-30

### Changed

- Stream liveness no longer counts gateway keepalives as progress: the body
  idle clock is restarted only by SSE lines that carry model output
  (`api/stream.zig isKeepaliveLine`), while transport bytes of any kind only
  refresh a "last byte" stamp that the stall report uses to say whether the
  gateway was pinging over a dead upstream or the connection itself died.
  The body-phase cap drops from 60 to 30 minutes (`STREAM_BODY_IDLE_CAP_MS`);
  a catalog `max_tokens` of 131072 had pushed the tolerated silence to the
  old cap. (2026-09-23 incident: 55 minutes of pings, zero output.)
- `tool_error`: `Aborted` is now `category: interrupted`, `recoverable: true`
  (new category). A user or host interrupt is neither the model's fault nor
  an environment fault; it no longer counts toward the `environment_fault`
  breaker.
- Zig source API: `PermissionContext` and `permission/decision.Context`
  replace `sandbox_enabled` / `auto_allow_bash_if_sandboxed` with
  `sandbox: ?*const SandboxSettings`, the same settings the Bash tool wraps
  commands with, so the permission verdict and the execution cannot
  disagree. On Windows (PowerShell/cmd) no Bash command is auto-allowed or
  run concurrently as read-only: the classification models POSIX `sh` only.

### Added

- Optional System-One (Jev) memory-plane advisor (`src/jev/`,
  [doc/JEV_SYSTEM_ONE.md](doc/JEV_SYSTEM_ONE.md)), off unless
  `METACODES_JEV_URL` is set; `METACODES_JEV_MODE` is `shadow` by default
  (consult and journal, provider-visible bytes unchanged) or `advisory`, and
  `METACODES_JEV_DECISIONS` narrows it to a subset of its surfaces. It
  advises four existing memory decisions and never gates a tool, permission,
  budget or TinyKG write: scoped recall ranks the BM25-plausible part of an
  8-hit pool (score at least half the top, the baseline's own band) by judge
  probability plus normalized BM25 once the BM25 floor has passed (the judge is
  not consulted below it), `KgRecall` gains a relevance/sufficiency block,
  `KgRemember` a same/contradicts relations block, and the enumeration judge
  arms only the soft coverage reminder. Judge failures fall back to the
  unadvised path without retries (30 s–5 min breaker); a user interrupt stays
  `Aborted`; a different model or a priced tariff is refused. Every
  consultation emits `system_one_decision`
  (`metacodes-system-one-decision-v1`): the scoped-recall decision on the
  evaluation stream, which the evaluation adapters validate, and the
  tool-surface decisions in the tool-observation journal.
  The paid memory runner gains `tinykg_jev`, the attribution arm
  `tinykg_jev_recall` (recall gate only) and the injection-only arms
  `tinykg_inject` / `tinykg_jev_inject` (TinyKG tools withheld, turn-level
  store) behind a loopback judge proxy, and
  `zig build eval:jev-recall-driver` replays LongMemEval-S candidate pools
  through the production recall policies with no provider.
- Release automation (`doc/RELEASE_AUTOMATION_DESIGN.md`): `scripts/release_cut.py`
  derives the next version from the Conventional-Commit types since the last
  tag, rewrites `build.zig.zon` / `src/version.zig` / this file in one release
  PR and reopens `-dev` afterwards; `release-tag.yml` tags a merged release PR
  and dispatches `release.yml`; `release.yml` also runs on a bare `X.Y.Z` tag,
  drafts with the CHANGELOG section as notes, updates an existing draft on
  rerun and never publishes a non-tag ref; `scripts/check_version_state.py`
  (in `doc:check`) closes the window between a release merging and reopen.

### Fixed

- The TinyKG web transport could report a timeout before `timeout_ms` on
  Windows. Its deadline was one sleep on the awake clock, which
  `std.Io.Threaded` turns into a relative NT wait; the kernel services that
  wait on clock-interrupt ticks, so it can end up to one tick (15.625 ms by
  default) early. The 35 s default and the readiness probe's 2 s are whole
  numbers of ticks, so a wait that started part-way into a tick ended early
  by up to that offset: a write could report `AmbiguousCommit`, which blocks
  every later write, before the daemon had its full timeout, and a read
  could spend the leftover milliseconds on a second request. The deadline
  now waits until the awake clock has passed it (`util/time.sleepAtLeast`),
  as the System-One client's does.
- `util/file_lock` could let two contenders hold one lock after its holder
  died. Both judged the dead holder's record stale; the first renamed it away
  and created a fresh lock, and the second's rename then moved that fresh
  lock away instead and created its own, so both went on to rewrite the
  shared file. Takeover is now single-winner per stale record: a contender
  first creates that record's claim file
  (`<path>.lock.claim.<fingerprint>.<generation>`, `O_EXCL`) and deletes the
  lock only if it still holds the record it judged stale, so a fresh lock is
  never moved or deleted. A claimant that dies mid-takeover leaves a claim
  that goes stale after `stale_ms`, and the next generation takes over. The
  lock guards the swarm mailbox and team config, the task-list mirror,
  provider config, transcripts and the TinyKG migration lock.
- The task-list mirror's temporary file was named from the monotonic clock
  alone (`<path>.tmp.<ns>`) and is created with `O_EXCL` on every write.
  macOS `CLOCK_MONOTONIC` ticks in 1 µs (Windows QPC commonly in 100 ns), so
  two writes in one tick would get the same name. It is now
  `<path>.tmp.<pid>.<ns>.<seq>` with a process-wide atomic sequence. The
  mirror lock already serializes its writers and no failure was observed;
  the name no longer depends on that lock to stay unique.
- Three maintainer rule-control sensors had drifted from the code they read
  and failed closed on a correct tree. The TinyKG bundle rule still required
  `metacodes.tinykg-bundle/v1` after the bundle moved to v2; it now reads the
  schema the bundle builder writes (`stage_tinykg_binary.BUNDLE_SCHEMA`). The
  paid-budget lock and treatment-resume rules looked for `O_NOFOLLOW` and the
  reattestation call where refactors had moved them into shared helpers
  (`model.open_nofollow`, `_validate_checkpoint_rows`); they now check each
  hop. `zig build test` runs the rule-control suite (`test:rule-control`),
  which observes every rule on the checked-in tree, so this kind of drift
  fails its own pull request.
- The maintainer rule-control gate also failed closed on a skipped test: the
  paid-budget rule's feedback runs `scripts/eval/workbuddy_release_suite.py`,
  whose roster of WorkBuddy tests that need an external checkout missed the
  one #110 added. The roster lists all ten again, and `zig build test` now
  checks that it is exactly the adapter tests that read
  `METACODES_WORKBUDDY_CHECKOUT` (`roster_violations`), where the old check
  only required the listed names to exist.
- Bash auto-allow no longer runs writes without a prompt. The read-only
  auto-allow (default, acceptEdits and auto mode) keyed on the first word of
  the whole command, so `cd / && rm -rf *`, `echo x > ~/.bashrc`,
  `sed -i …`, `find . -delete` and `ls; curl … -o x; sh x` ran unprompted.
  `permission/bash_readonly.zig` now lexes the command the way `sh` does
  (after the Bash tool's own JSON unescape) and accepts it only when every
  simple command is read-only: no substitution, background job, subshell or
  heredoc; output redirection only to `/dev/null` or a descriptor; write
  options refused per command (`sed -i`/`w`/`e`, `find -delete`/`-exec`,
  `sort -o`, `uniq IN OUT`, `awk` redirects and `system()`, `file -C`,
  `rg --pre`, `git --output`/`branch NAME`/`config` writes, `printf -v`,
  including GNU long-option abbreviations and quoting that spells them;
  `git remote show` needs `-n`, since without it git queries the remote);
  wrappers (`timeout`, `time`, `nice`, `stdbuf`, `xargs`, `command`) parsed
  with their real options; `env`, `exec`, `nohup` and `cd … && git …` ask.
  Anything it cannot parse asks. The concurrency gate
  (`tools.isConcurrencySafeInput`, which also governs stream prefetch) uses
  the same verdict. `rg` joins the read-only roster.
- `autoAllowBashIfSandboxed` allowed every Bash call whenever the setting
  was on, although off macOS (no Seatbelt), for `excludedCommands` and for
  `dangerouslyDisableSandbox` the command runs outside the sandbox. It now
  allows only a call `sandbox_exec.plan` says will run sandboxed, and a host
  without a sandbox backend logs a warning at load.
- `dangerouslyDisableSandbox` (not in the Bash schema) was honored even
  under `allowUnsandboxedCommands: false`, the setting AgentCore's sandboxed
  shell policy uses; it now takes effect only where that setting allows it.
  A sandbox profile that cannot be written no longer makes Bash or Monitor
  run the command unsandboxed; the call fails instead.
- Bash `deny` and `ask` permission rules now match a compound command when
  any segment matches (after wrapper stripping): `Bash(rm *)` catches
  `ls && rm x`, `ls; rm x`, `ls | rm x` and a newline-separated `rm x`. They
  used to require every segment to match, like `allow`, so a harmless prefix
  defeated the rule: `bypassPermissions` and `autoAllowBashIfSandboxed` ran
  the command, and `default` asked instead of denying. `allow` rules still
  need every segment (`permission/rule_spec.zig matchesBashCompound`). Rules
  are now matched against the command the shell receives (the Bash tool's
  own field lookup and JSON unescape), so `\n`, `\u0026\u0026` and `\"`
  are real separators and quotes: `Bash(npm *)` no longer auto-allows
  `npm test\nrm x`. Heredoc bodies are not parsed, so each of their lines
  is a segment of its own.
- Legacy `permission_rules` in `~/.metacodes/config.json`
  (`permission/rule_matcher.zig`) now split compound commands too. Their
  `command_prefix` was a `startsWith` over the whole, still JSON-escaped
  `command`, so an `allow` for `git ` approved `git status && rm -rf ~` (and
  `git status\nrm -rf ~`), and a `deny` for `rm ` missed `ls && rm x`. The
  command is now unescaped as the Bash tool does it and split into segments.
  These rules are first-match-wins in array order, so the first matching rule
  is taken for every segment, and for the whole command so that a prefix
  spanning a separator still matches, and the strictest result wins: any
  `deny` denies, otherwise any `ask` asks, otherwise the command is allowed
  only when every segment is, and the mode decides the rest. An earlier
  `ask` no longer hides a later `deny` on another segment, and an `allow`
  exception listed before a general `deny` still covers its own segment. A
  command inside a wrapper (`timeout`, `nohup`, `env`, ...) is matched again,
  but only its `deny` and `ask` count: `env LD_PRELOAD=... git status` is not
  allowed by `git `. A command that cannot be split (out of memory) gets the
  strictest result the rules could reach.
- A Bash `allow` rule in settings.json approved commands it does not name.
  Every rule kind was matched against `bash_parser.stripWrappers`, which drops
  `env` together with its `KEY=VAL` arguments and drops `xargs`, so
  `Bash(git *)` allowed `env LD_PRELOAD=/tmp/x.so git status`,
  `env PATH=/tmp/evil:$PATH git status` and `xargs git rm`. Since `allow` is
  evaluated before `ask`, such a match also hid the user's `ask` rules, under
  `bypassPermissions` too. An `allow` rule now matches a segment as written,
  or the command inside a wrapper that only changes how it runs (`timeout`,
  `time [-p]`, `nice`, `ionice`, `nohup`, `stdbuf`, `command [-p]`, `exec`),
  parsed with that wrapper's real options (`bash_parser.peelBenignWrapper`):
  `Bash(npm test)` still allows `timeout 30 npm test`. `deny` and `ask` rules
  still see through every wrapper, and now also match the command as written
  and each wrapper layer: `Bash(xargs *)` catches `xargs rm`, `Bash(env *)`
  catches `env X=1 make`, and `timeout -s KILL 5 rm x` triggers `Bash(rm *)`.
- The compound splitter behind Bash permission rules
  (`bash_parser.splitCompound`) cut descriptor redirections at their `&`:
  `npm test 2>&1 | tail -20` became the segments `npm test 2>`, `1` and
  `tail -20`, so `Bash(npm test *)` did not allow `npm test 2>&1` (the `1`
  segment matches nothing) and one of the most common agent commands asked.
  An `&` right after an unquoted, unescaped `>` or `<` (`2>&1`, `>&2`, `<&3`,
  `>&-`) and a `|` right after `>` (`>|`) now belong to the redirection;
  `&&`, a lone `&`, `|&`, `;`, `|` and newline still separate. `&>` and `&>>`
  still split at the `&`, the way dash reads them (a background job, then a
  command that is only a redirection); under bash they redirect both
  streams, and the extra `> file` segment only makes an `allow` rule ask.
- Injected memory lines are cut on a UTF-8 boundary. Scoped recall's 320-byte
  `firstLine`, the KG startup summary's `firstLineTrunc` and the REPL's
  `firstLine` backed off while the last kept byte was a continuation byte,
  which strands the lead byte of a character cut at the limit: a CJK memory
  reached the provider with a trailing U+FFFD and the scoped recall receipt
  hashed different bytes than the provider received. All three use
  `util/utf8.prefixEnd`.
- Paid memory pilots could not run a TinyKG arm since TinyKG storage v3: an
  online (read-write) rollout store's sibling daemon-ownership lock
  (`<store>.tinykg-daemon.lock`) was outside the production Seatbelt
  profile, so every TinyKG command in the child got `PermissionDenied`, KG
  degraded, and treatment activation refused the arm. The carve-out that
  sealed offline stores already had now covers read-write stores as one
  literal path. The memory runner and replay also split JSONL on LF only:
  `str.splitlines()` cut records at U+2028/U+0085 that stay raw inside
  LongMemEval chat text.
- A Ctrl+C/Esc while the provider stream read was blocked was reported as a
  model API error: `provider.cancel` shuts the socket, the read wakes with
  `ReadFailed`, and the stream clients classified that before consulting the
  abort signal. All three clients (and `agent_loop` as a backstop) now report
  `Aborted`, keep the streamed prefix as partial text, and the REPL resets the
  abort signal at every run boundary instead of only after `.aborted`, so a
  stale flag no longer kills the next queued message on its first millisecond.
- `environment_fault` is emitted after the `tool_result` it belongs to, so the
  TUI prints the warning under the right tool card.
- Bash-tool children (`platform/process.spawnToFiles`) get `/dev/null` on
  stdin instead of inheriting the controlling terminal: a child in its own
  process group that read the tty (`ssh` without `-n`) was stopped by SIGTTIN
  and never exited.

- A context-window rejection from the provider is now a measurement and a real
  compaction, not a one-pair shave. `recoverContextWindowExceeded` reads the
  server's numbers from the error body (Anthropic, OpenAI-compatible/GLM and
  Gemini wordings; `error_class.parseContextWindowNumbers`), records the wall
  per (endpoint, model) in `~/.metacodes/context_caps.json`
  (`core/context_caps.zig`, override with `METACODES_CONTEXT_CAPS_FILE`), marks
  the conversation full, runs the summary compaction once per turn and retries
  the same turn; trimming the oldest pair is only the fallback when nothing is
  compactable. Thresholds derive from `min(catalog window, learned cap)` and
  the 13K/20K/3K buffers scale with the window above 200K. Automatic
  compaction keeps the user's requests verbatim in the summary (20K-token
  budget, bounded to a quarter of the dropped prefix, first request always;
  `compact_kernel.Options.preserve_user_prompts_tokens`, off for manual and
  public compaction) and its fallback without a model summary keeps them too.
  Both UI
  backends render the two `context_window_exceeded_*` causes as recovery.
  Before this, a catalog window above the real wall (Metask glm-5.3-flash:
  917,504 derived vs ≈883K observed) pinned a session at the edge: 75
  rejections in 21 minutes, two messages dropped per turn, the prompt cache
  broken every turn, the original task dropped with no summary.
- `UiEvent.queue_message` and `UiEvent.interrupt` were declared by the UI
  protocol and produced by `TuiBackend.poll`, but no production path ever
  called `UiBackend.poll` (#115): the CLI implemented queued messages entirely
  at the REPL layer, so a message typed during a Run could not reach the
  Conversation until the whole Run had finished, and a source-level embedder of
  `metacodes-core` had no way to steer an active Run. The agent loop now
  drains `poll` at every turn boundary (previous tool_results appended, next
  provider request not yet built; never during a stream, and not at the
  boundary right after a max_tokens truncation, so a continuation stays one
  answer): a `queue_message` is appended as a user message and rides the very
  next request of the same Run (blank messages are dropped; the slice is freed
  with the Run's allocator, so in-process backends allocate it with that
  allocator), and an `interrupt` ends the Run there as `aborted`
  (`evaluation_budget` → `budget`) without replacing AbortSignal's mid-stream
  interruption. `TuiBackend.poll` hands over plain prompts only: `/commands`,
  `!shell` and `exit` stay queued in order for the REPL to dispatch after the
  Run, a consumed message is echoed (`❯ …`, same layout as the between-Run
  echo) and added to the readline history, and a message taken just as Esc
  aborts the Run is put back so it is resubmitted afterwards as before. The
  queue preview now renders under the queue lock instead of from borrowed
  slices. Messages still queued when a Run ends become the next Run's input
  exactly as before, the web backend keeps its between-Run semantics, and the
  AgentCore binary ABI is unchanged: it has no active-Run input operation, its
  backend poll returns null, and `doc/AGENTCORE_BINARY_ABI.md` now states the
  Host-side queueing contract. `tests/component/ui_queue_message_test.zig`
  proves the queued text appears in the second request of the same Run after
  the tool_result, that a boundary interrupt stops before a second request,
  that whitespace is dropped, and that the continuation boundary is not
  polled; `ui_backend_test.zig` covers the command gating and the history.
- Windows: `platform.fs.realpath` resolved paths lexically (`_fullpath`), so a
  `metacodes.exe` started through an NTFS symlink or junction reported the
  invoking path as its physical path and every adjacent lookup (`bin/rg.exe`,
  `libexec/metacodes/<kernel>.exe`, `vendor/tinykg/`) searched beside the link
  (#140). A new `platform.fs.finalPath` resolves an existing path through a
  handle (`CreateFileW` + `GetFinalPathNameByHandleW`, `\\?\` and `\\?\UNC\`
  prefixes stripped; null when the path cannot be opened, like POSIX
  `realpath`) and `selfExeRealPath` uses it. `realpath` itself stays lexical
  on Windows on purpose — callers compare its output against paths they built
  themselves (workspace root, permission rules, memory directories), and the
  physical form (on-disk case, long names, mapped drives expanded to UNC)
  would stop matching — but it is now the wide `_wfullpath`, so CJK
  components survive. The `paths.zig` symlink test runs on Windows when the
  runner may create symlinks, a junction variant (`mklink /J`, no privilege
  needed) was added at unit and process level, and `adjacent_symlink_test`
  starts the real `selfexe_probe.exe` through a symlink and through a junction.
- Windows: path-taking CRT calls decoded UTF-8 paths with the process ANSI
  code page (#121). File creation (`_open`) and every directory creation
  (`_mkdir`) were narrow while the existence checks, `statPath`, unlink and
  rename were wide, so one path string named two filesystem objects: `Write`
  could pass its must-read-first check on `测试.txt` and then truncate the
  code-page counterpart (`娴嬭瘯.txt` under CP936), and CJK parent directories
  were created under the wrong names. `platform.fs` now converts to UTF-16
  for every path-taking entry point — `open` (`_wopen`, `_O_BINARY` kept),
  new `mkdir`/`rmdir`/`chdir`/`chmod`/`fopen`/`getCwd` (`_wmkdir`, `_wrmdir`,
  `_wchdir`, `_wchmod`, `_wfopen`, `GetCurrentDirectoryW`), `realpath`
  (`_wfullpath`) — and every production `std.c.unlink`/`rename`/`access`/
  `chdir`/`fopen`/`mkdir`/`rmdir`/`chmod` call in `src/` goes through those
  wrappers, so a file created wide is also deleted, renamed and probed wide
  (the file lock, suspend state, goal file, the kgd install temp holding an
  API key, `.git` and `MEMORY.md` discovery, the KG pointer files). The input
  side is fixed with it: `homeDir`/`tempDir` read the environment through
  `GetEnvironmentVariableW` and `getCwd` through `GetCurrentDirectoryW`, so a
  CJK user profile or working directory reaches the wrappers as UTF-8 instead
  of ANSI bytes the strict conversion would reject. `Write`, `ApplyPatch` and
  the worktree tool share one `mkdir -p` walker (`util.fs.mkdirAll`, with a
  fast path when the directory already exists). `NOFOLLOW`/`isSymlink` decide
  by reparse *tag* (symlink or junction), so OneDrive placeholders and other
  reparse-tagged regular files are no longer refused as links. errno is no
  longer converted with a bare `@enumFromInt` (a value `std.c.E` does not name
  panicked in Debug/ReleaseSafe): callers compare integers (`lastErrnoIs`) or
  look the name up (`errnoTag`/`errnoName`); the wrapper sets errno and
  `GetLastError` itself when it refuses an operation (`ENAMETOOLONG`/`EINVAL`
  for an over-long or invalid path, `ELOOP` for a `NOFOLLOW` open of a link);
  `unlinkPath` reports `NotFound` separately so idempotent cleanup no longer
  guesses with a second `exists()` (logout reported success while the
  credentials file remained when both calls failed for a permission reason).
  Tests create `测试目录/测试.txt` through the wrappers and verify the exact
  names through `std.Io` and directory enumeration, drive `chdir`/`getCwd`/
  `fopen`/`chmod` through a CJK directory, read a CJK environment value back
  as UTF-8, and on Windows seed the ANSI-decoded counterpart and prove `Write`
  leaves it untouched.
- Adjacent-artifact resolution disagreed across resolvers when `metacodes` was
  started through a symlink (the common `ln -s <prefix>/bin/metacodes
  ~/bin/metacodes` install): macOS reports the invoked symlink as the
  executable path, so the release-layout lookups for `bin/rg` and both Lean
  kernels landed in `~/bin` — rg silently fell back to a PATH copy with a
  non-matching digest and the pinned kernels were unresolved (`doctor --strict`
  red, project-rule activation failing closed) — while the TinyKG lookup, which
  already applied `realpath`, resolved. All three now derive their prefix from
  one helper, `platform.paths.selfExeRealPath` (self-exe path resolved through
  `realpath`; a relative invoked path is refused outright, and the fallback to
  the invoked path applies only when `realpath` fails). The REPL's TinyKG client no longer receives an
  `argv[0]`-derived executable directory (forgeable, empty for a bare-name
  `PATH` start, and a second basis next to the OS-reported one); it uses the
  same helper.
  A new process-level harness (`selfexe_probe`) is copied into a staged prefix
  and started through a symlink in another directory to prove rg and both
  kernels resolve beside the physical binary.
- Image input was rejected locally (`image_input_unsupported`, status 28, no
  HTTP request) for non-Claude vision models reached through an Anthropic
  Messages-compatible endpoint, because the Anthropic profile only granted
  vision to names containing `claude` (#112). `provider_kind: anthropic`
  selects the wire format, not the model family: vision is now resolved in
  two layers — the catalog's per-model `image_input` declaration wins when it
  names the model, otherwise one route-independent family table
  (`model_adapter.knownVisionFamily`: Claude 3+, OpenAI GPT-4o/4.1/4.5/5 and
  o-series, Gemini, Qwen VL, GLM-V) shared by the Anthropic and
  OpenAI-compatible profiles — so `gpt-5.6-sol` gets the same answer on both
  routes and the image goes out as an Anthropic base64 `image` source block.
  Text models and unknown names on either route still fail closed before any
  network I/O. The AgentCore ABI suite now proves the positive path end to
  end: a multimodal Run on the Anthropic route for `gpt-5.6-sol` is admitted
  and the provider receives exactly one request carrying the image bytes.
- Stream liveness killed legitimate long tool calls: the idle clock was reset
  per parsed event, so a tool call's `input_json_delta` frames, SSE pings and
  unknown events counted as silence, and the flat 120 s limit also applied to
  the body phase, where a gateway may generate an entire 20-40 KB tool call
  before writing a byte of it (a 126 s call died as `StreamStalled` although
  bytes arrived every second). All three transports now reset the clock on
  every transport read (`LivenessReader`), the request switches from the strict
  head-phase limit (`METACODES_STREAM_IDLE_TIMEOUT_MS`) to a body-phase limit
  scaled by `max_tokens` (`METACODES_STREAM_BODY_IDLE_TIMEOUT_MS`, default
  `clamp(max_tokens × 100 ms, 10 min, 1 h)`) once the response head is
  accepted, and a body-phase stall records the idle time and limit so the TUI
  prints `正文空闲超时: N ms 内无任何字节(上限 M ms)` instead of the generic
  "重试耗尽 / 后端错误 / 上下文超限" guess.
- Child agents could inherit a provider default instead of the lead's current
  effort: the parent logged `none` while a GLM-5.2 child logged `default` and
  consequently enabled thinking. Child resolution now follows AgentDef
  `effort`, explicit Task model-tier effort, inherited parent effort when the
  model is unchanged, then the selected model's default; this also preserves
  an explicit `.none`.
- Per-call providers could fall back to unrelated hard-coded limits. The
  provider factory now passes `ModelLimitsSource`: registries own immutable
  catalog snapshots and App refreshes them after catalog changes, avoiding
  worker races with `/model` rebuilds and probes. OpenAI/Gemini resolve input
  windows through ModelContext; their output limit and `--max-tokens` semantics
  remain unchanged (the override applies only to Anthropic).
- Model routing, capability, pricing, catalog, and context-window matching is
  now ASCII case-insensitive through `model_name.zig`; the model string sent
  on the wire remains unchanged. The GLM-5.2 note also records that the
  2026-07 historical 262144 window became 1048576 on 2026-09-05 (1,001,205
  input tokens succeeded; 1,101,379 was rejected).

### Changed

- CI, AgentCore Windows, Release and Maintainer rule control all run on
  GitHub-hosted runners (`ubuntu-latest`, `macos-latest`, `windows-latest`):
  the repository is public, hosted standard runners are free for public
  repositories, and organization policy keeps public repositories off the
  self-hosted fleet. Runner-specific machinery is gone — the fork-isolation
  `if:` guards, the persistent per-machine Zig/Lean cache directories, the
  per-machine `concurrency` lanes, `-j6`/`-j12` sized for the old boxes, and
  `release.yml`'s `runner_pool` input. In their place: `mlugg/setup-zig`'s
  `use-cache` for the Zig cache, `actions/cache` for `~/.elan` and
  `control-plane/lean/.lake`, `scripts/ci/install-elan.sh` (elan from a
  pinned release asset with a pinned SHA-256; a no-op on a cache hit),
  `requirements-dev.txt` installed on every leg, and `cargo install
  bindgen-cli --version 0.72.1 --locked` in the release jobs. Job timeouts are
  45 min for the gates (cold hosted runners compile the whole tree) and
  unchanged elsewhere. `doc/RELEASE_RUNNER.md` now describes the hosted
  release pipeline; the dedicated `metacodes-release` pool is no longer
  planned.

- Vendored ripgrep moves from 14.1.1 to 15.2.0 (#86): the four existing
  targets are replaced by the upstream 15.2.0 release binaries and
  `rg-linux-aarch64` (upstream's `aarch64-unknown-linux-musl`, static-pie,
  first published in 15.x) joins `vendor/ripgrep/manifest.json`, so
  `aarch64-linux` satisfies the `elf-static` contract that #79 fails closed
  on. Glob/Grep pass only `--files`, `--no-messages`, `--glob`, `--type`,
  `--no-filename` and `--multiline-dotall`; the 15.x notes change none of
  them. Every asset digest was checked against the GitHub Releases API.

### Added

- Progress updates during multi-stage tasks (#114). The shared Core forwarded
  and classified whatever visible text the model produced, but a model that
  called tools round after round without writing a word left the user with
  nothing but tool lifecycle events, and the default prompt's brevity rules
  pushed in that direction. Two provider-neutral changes. The default system
  prompt gains a short "Progress updates on longer tasks" section that defines
  the expectation (a sentence or two at natural milestones — stage, findings,
  next step — outranking the brevity rules on multi-stage work; never for
  single-step tasks, never per tool call, never private reasoning); this
  changes the static prompt prefix once, so the prompt cache is intentionally
  invalidated one time on upgrade and stable afterwards. The agent loop gains
  a bounded progress-update obligation shaped like the delivery-cadence gate:
  a silent stretch — consecutive tool rounds with no visible model text
  (whitespace and host-rendered decorations do not count; text the loop
  continued past, or that max_tokens cut off, does) — that is long enough in
  both rounds and wall-clock time (`Options.progress_update_thresholds`,
  defaults 3 rounds and 10 s) earns one host message at the turn boundary
  asking for a short progress note in the same reply, then the continuation.
  At most two decisions per Run, counted by the shared host-injection meter
  (cap 11 → 13, mirrored in Lean and now pinned by a comptime `cap = Σ`
  assertion), the stretch restarting after each decision. It is a
  host-contract field like its siblings: off in `agent_loop.Options`, left off
  by canonical `buildRunOptions` (macro runs, skill runs and AgentCore hosts
  are not nudged), switched on by hosts with a reader — the interactive REPL,
  the web session and `--stream-json` print mode — and only for a Run whose
  commentary a person can read (`event_projection`); `--no-progress-updates`
  turns it off, `--progress-updates-observe` records decisions without
  injecting. A terminal `progress_updates` observation record (decisions,
  nudges, longest stretch, thresholds) is emitted for the eval trace parser,
  whose policy check is lockstep-tested against the Zig bound and the new
  `ProgressUpdates.lean` policy model (narration resets, below either
  threshold never fires, decisions bounded over any trace). Host-injected user
  records are no longer mistaken for the user's own words: `latestUserText`
  (web-search display query), the transcript viewer and `/recap` skip or
  label them. The reply is ordinary `commentary` (or the final answer if the
  model ends the turn); the output-segment protocol is untouched.
  `tests/component/progress_updates_test.zig` drives the loop through silent,
  narrated, continued-text, whitespace, bounded, time-floored, observe, off,
  subagent and single-step shapes and asserts on the real request bytes,
  segment dispositions and the terminal record;
  `session_api_parity_test.zig` pins the canonical exclusion.

- `providers.<id>.oauth_client_id` in `~/.metacodes/config.json` (#87): the
  OAuth client an installation registered for a built-in profile that declares
  none. `metacodes login --provider <id>`, `/login <id>` and the picker's
  credential stage present it without `--client-id`; precedence is
  `--client-id`, then the configured client, then the profile's declaration,
  and the winner is recorded with the login as before. Built-in profiles keep
  declaring none.

- `.github/workflows/release.yml` (#82, #47 stage 7): `workflow_dispatch` with
  `tag`, `dry_run` and `runner_pool`; one job per platform on the dedicated
  `metacodes-release` runner label (the CI pool only for dry runs) running the
  attested-asset checks, the ReleaseSafe suite, `release:verify`,
  `agentcore:gate`, both archives and a byte-for-byte reproducibility check;
  a `publish` job — the only one with `contents: write` — joins the checksums
  and creates a *draft* GitHub Release with `--verify-tag`. The tag trigger
  stays off until the runners exist; `doc/RELEASE_RUNNER.md` is their design.

- `zig build release:archive` writes the immutable CLI release archive
  (`metacodes-<version>-<target-id>.tar.gz` / `.zip` plus `.sha256`) from the
  verified prefix, byte-identical across runs (fixed gzip name and mtime, no
  owners or timestamps in members); `release:sums` joins the sidecars into
  `metacodes-<version>-SHA256SUMS`. The archive core moved from
  `package_agentcore.py` to `scripts/release_archive.py --kind agentcore|cli`;
  a stable version archives only from a clean tree tagged with the bare
  `X.Y.Z`, a pre-release from any commit, and the SDK keeps its historical
  refusal text (#81, #47 stage 6).

- The CLI release unit (#80, #47 stage 5): `zig build release:stage` installs
  the product files plus `share/licenses/{metacodes-LICENSE, tinykg-LICENSE,
  THIRD_PARTY_NOTICES.md}` and `share/doc/{README.md, CHANGELOG-<version>.md}`;
  `release:manifest` writes `manifest.json` (`release/manifest.schema.json`,
  `release/manifest_contract.zig`, `release/LAYOUT.md`) from git, the vendored
  manifests and the installed files; `release:check` runs the static checks
  and `release:verify` also the executable-running ones on the native target
  (`scripts/verify_release_bundle.py`). A version without a pre-release part is
  the stable channel and requires a clean tree tagged with the bare `X.Y.Z`;
  main now carries `0.2.0-dev`, and `--version` reports `0.2.0-dev+<commit12>`
  exactly as the manifest does. The repository gains its MIT `LICENSE`.

- The default install stages the vendored ripgrep beside the executable as
  `bin/rg[.exe]` with its MIT notice under `share/licenses/`, and the new
  `zig build release:stage -Drelease-layout=true` installs the release layout,
  failing closed for a target without vendored runtime assets (aarch64-linux
  until #86). Under the release layout the executable resolves rg as `RG_BIN`
  → its own directory → `PATH` (the development order is unchanged), and
  `verify_install_prefix.py --release --doctor` proves it on the installed
  prefix in CI (#79, #47 stage 4, B2).

- `metacodes --version` prints the build identity after its unchanged first
  line, and `--version --json` emits it as one document: commit and dirty
  state, Zig, target, optimize mode, release layout, AgentCore ABI version and
  revision, config schema version, and the ripgrep / TinyKG versions with the
  digests pinned for the target. `build.zig` fixes every value at configure
  time from its source (`-Dbuild-commit` names the commit for an exported
  tree; `-Drelease-layout` records the layout), and the runtime smoke checks
  the document against `sdk/zig/types.zig` and the vendored manifests with
  the real binary. `metacodes doctor [--json] [--strict]` reports where ripgrep
  and TinyKG resolve from and whether their digests match the pinned ones;
  `verify_install_prefix.py --doctor` runs it on the installed prefix in CI
  (#78, #47 stage 3).

- The model picker signs in without leaving the overlay (#67): a commit that
  fails for want of a credential on an OAuth-capable provider runs the kernel
  login on a worker thread, draws the authorization URL or device code in the
  picker, cancels on `Esc`, and commits the chosen route once the login lands.
  The OAuth loopback wait and the device-code poll honour an `AbortSignal`
  (`platform/net.pollReadable`), so a login abandoned in the TUI no longer
  blocks until its timeout.

### Changed

- The default `zig build` installs only the release executable and the TinyKG
  bundle (B1, #77): `metacodes-debug` comes from `zig build dev`, and
  `mock_mcp_server` / `replay_server` from the new `zig build test:harness`;
  the TTY and e2e steps depend on those installs explicitly.
  `scripts/verify_install_prefix.py` asserts the exact prefix contents and runs
  in CI on every platform.

### Fixed

- AgentCore child agents (Task / fork / model-invoked Skill) no longer exhaust
  the Session durable budget with bytes the checkpoint never stores. The child
  ran on the parent's `BudgetedProvider` and a `ToolEnvironment` bound to the
  parent's `Controller`, and every child assistant increment and tool result
  settled as durable — yet the child's Conversation is discarded when it
  returns and only its final text re-enters the Session. A subagent-heavy Run
  therefore reached `budget_exhausted` (hosts render it as a budget stop, the
  Task result carries `checkpoint_budget_exhausted`) while the real checkpoint
  was far below `hard_bytes`; reported on a GLM-5.2 session whose subagents
  were verbose enough to trip it. `session_budget.DurableScope` now separates
  the two: a `.transient` operation still reserves its request and payload cap
  while in flight and an oversized child result is still a resource limit, but
  settle adds nothing to `estimated_usage_bytes`. The fork-root final text is
  charged once through `Controller.commitDurable` before `runIsolated` appends
  it (a commit that does not fit withholds the text and ends the Run
  `.budget`); the model-tool child's final text is already charged as the
  parent's tool result.

- `scripts/eval/tests/test_plugin_release_gate.py` did not import on the macOS
  system python3 (3.9): a `list | None` parameter annotation is evaluated at
  definition time (`type.__or__` is Python 3.10) in a module that does not
  defer annotations, so the eval-suite discovery in `zig build test` died at
  collection while CI's newer interpreter never saw it. The module now opens
  with `from __future__ import annotations` like the rest of scripts/, and
  `scripts/tests/test_python_floor.py` reports every PEP 604 union in an
  annotation of a module without that import, and every `X | None` outside an
  annotation (a type alias, an `isinstance` argument), which the import does
  not defer.

- Headless `--stream-json` and `--json` NDJSON lines are always valid UTF-8.
  The stream backend and the `result` line encoded strings with
  `std.json.Stringify.encodeJsonString`, which passes bytes 0x80–0xFF through
  untouched, so a `tool_result` carrying binary tool output (a ReportLab PDF's
  `%\x93\x8c\x8b\x9e` marker read with `Read`, observed on the 2026-09-05
  WorkBuddy office cohort) reached stdout as raw bytes and a strict UTF-8
  consumer rejected the whole file. Every string field now goes through the
  repository's canonical encoder (`util/json.zig`, invalid bytes → U+FFFD;
  `content_bytes`/`input_bytes` still count the raw payload), a `text` or
  `thinking` delta cut inside a multi-byte character is held back and rejoined
  losslessly with the next delta of the same kind, and a character the block
  ends without completing is emitted as one explicit U+FFFD line.

- The Bash tool's spilled stdout/stderr are sealed during execution as attachments
  of its inline result and published by the batch commit boundary, like every
  other tool result since #45/#65; a fatal sibling in the same batch leaves no
  blob, and a channel whose publication fails has its artifact id withdrawn from
  the JSON (`<channel>_artifact_id: null`, `<channel>_storage_error`,
  `<channel>_recoverable: false`) instead of dangling. `tool_result.SealedHandles`
  carries up to two handles per result through `tool_exec` and the prefetch;
  `artifact_store.sealFileCopy` seals a copy of a foreign private file. Callers
  without a batch boundary (`!cmd`, embedders) keep the execution-time resolution
  through `bash.execute`. The MCP projector's above-frame-limit result range
  (`mcp_result_stream.publishRange`, classic client and AgentCore runtime alike)
  and the AgentCore durable-budget promotion (`promoteInline`) seal too, so no
  producer publishes a tool result into the CAS during execution any more; a
  publication that fails at the boundary for a result above the retention ceiling
  is the bounded `ArtifactPublishFailed` tool error (#73).

- `scripts/build-project-harness-kernel.sh` failed its first smoke on every
  platform (`invalid project harness request: expected ,`, exit 64): the
  kernel has read `within_root` after `file_mutating` in every pre-decision
  signal since 33cf238 (2026-08-17), the script's hand-written canonical
  requests never gained the field, and no CI job ran the script. The smoke
  requests now carry `within_root`, two escape probes assert that a target
  outside the project root blocks under both the effect-class rule and the
  existing-file scope, and the `gates` job builds and smokes the kernel on
  Linux and macOS right after `lake build`.

- The paid plugin runner observed and executed the live checkout, so a pinned
  input replaced during a provider request and restored before the after-request
  check went unnoticed (#61, the paid-path form of the #49 gap). `run_paid_pair`,
  `--freeze` and the analysis now read the protocol once, refuse a pinned input
  that is modified in the working tree, materialize Git HEAD into a private
  directory and observe and execute there; each run directory is moved under
  the output directory before its evidence is imported.

### Added

- `THIRD_PARTY_NOTICES.md` is rendered by `scripts/gen_third_party_notices.py`
  from the dependency manifests (ripgrep, TinyKG, highlight-zig, the Lean
  toolchain) plus `release/notices.static.md`; `--check` fails with a diff when
  the committed file is stale, as `zig build release:notices` (part of
  `doc:check`) and a Linux CI step. The rows now carry the pinned commits and
  upstream revision. Stage 1 of #47.

- The pre-submit checklist has one source, AGENTS.md "Before submitting":
  `zig build gate:pr` runs it, `CONTRIBUTING.md` and the pull-request template
  point at it instead of repeating it, and `scripts/tests/test_gate_manifest.py`
  asserts that every checklist command has a CI step (CI gained the
  `git diff --check` step it lacked). Stage 1 of #47.

- `/login <provider> [--device-code] [--no-browser] [--client-id <client>]`
  in the REPL runs the kernel OAuth flow and stores the login where
  `metacodes login --provider` does. Both entry points share
  `src/api/provider_login.zig`: `prepareProfile` makes every refusal a typed
  error before anything is contacted, `Prepared.run` runs the grant and the
  one durable import. A picker commit that fails for want of a credential on
  an OAuth-capable provider now names `/login <provider>` (#33; the picker's
  own credential stage and the built-in OpenAI client id are #67).

- Metask now has a JSON device-code OAuth provider (`login --provider metask`)
  with rotating refresh-token persistence, gateway-derived model routing for
  Anthropic Messages and OpenAI Chat, one-shot replay for pre-stream
  `token_expired` responses, case-insensitive `X-Metask-Request-Id` capture,
  and the opt-in-path `metacodes ledger metask` NDJSON billing ledger. See
  `METASK_SITE_URL`, `METASK_GATEWAY_URL`, `METACODES_OAUTH_DIR`, and
  `METACODES_LEDGER_DIR`.

- `scripts/check_doc_facts.py` with the registry `release/doc_facts.json`: a
  fail-closed documentation fact gate. Each registered fact names one in-tree
  authority (the AgentCore ABI revision in `sdk/zig/types.zig`, the CLI version
  in `build.zig.zon`, the TinyKG and ripgrep versions in their manifests) and
  the documents that state it; every match must equal the authority, and a
  pattern that no longer matches anything fails as a detached sensor rather
  than switching the check off. Runs in CI and as `zig build doc:check`. The
  README, ROADMAP and plugin documents that still said ABI revision 13 or 14
  now state the declared revision, and the two `## 0.1.0` headings below are
  merged into one. (#47, stage 0)
- The provider-offer capability vocabulary's comptime coverage guard now binds
  the real runtime capability enum instead of a hand-copied duplicate, so the
  next runtime capability added without an offer mapping is a compile error
  rather than a silent gap.

### Fixed

- MCP results above the frame limit, host stream tool artifacts and process-plugin
  external spools (`ExternalSpool.seal`) are sealed during execution and published
  only at the batch commit boundary, like native tool results since #45: a fatal
  sibling in the same batch leaves no unreferenced blob in the CAS (#65). Bash's
  stdout/stderr import and the AgentCore-side producers still publish during
  execution and are tracked in #73.

- The fingerprint refresh wrote its staging file with `Path.write_text(newline=)`,
  a Python 3.10 call, so every suite whose setUp repins failed on the macOS
  system python3 (3.9); it now uses `open(..., newline="\n")`, and the 82 test
  fixtures that made the same call go through `scripts/eval/tests/textio.py`.
  The floor (3.9) and PyYAML are declared in `requirements-dev.txt`, an older
  interpreter or a missing PyYAML fails with a clear message, and
  `scripts/tests/test_python_floor.py` keeps every script parseable at the floor
  and free of that call (#59).

- Restored the invariant that a fatal batch does not persist a completed transient
  result (#45). Large captures now seal during execution and publish at the batch
  commit boundary, keeping the envelope reference and CAS publication atomic.
  Failures use the existing inline fallback policy or a bounded
  `ArtifactPublishFailed` tool error; other execution-time producers are tracked
  separately in #65.

### Changed

- Embedding AgentCore is described once: `doc/LIB_API.md` §3/§4 and the
  AgentCore section of `doc/API.md` keep a lead-in and the fact-gated
  sentences and point at `doc/AGENTCORE_BINARY_ABI.md`; `README.md` points at
  `sdk/README.md` for the bundle and gate commands. Stage 1 of #47.

- Superseded design documents (the revision-14 plugin ABI plan, the MCP
  transport hard-cut, the multi-session refactor, the DeepSeek harness analysis,
  the U2 and U9/U10 designs) and the inbound requirements formerly under
  `doc/frommetawork/` now live under `doc/history/`: records, not contracts,
  outside `release/doc_facts.json`. `doc/TREE_SITTER.md` is deleted (the feature
  was removed on 2026-07-13). Stage 1 of #47.

- `ReadArtifact` recovery reads are bounded per turn. Recovery results stay
  exempt from projection (spilling one would recurse), so nothing could trim
  them: nine parallel reads on a 200K window cost 225,000 bytes against a
  204,800-byte turn and squeezed every sibling to its minimum. The agent loop
  now charges each `ReadArtifact` call its upper bound
  (`result_budget.recoveryReadCost`) in slot order before execution and defers
  every call past half the turn budget (`recoveryAllowanceBytes`): a deferred
  call gets a bounded `recovery_allowance_exhausted` body carrying its
  artifact id and offset instead of data, and a `policy_decision` event with
  source `recovery_allowance`. Slot order at the upper bound keeps the
  decision independent of thread timing, so provider-visible bytes do not
  depend on scheduling. (#40)

- The zero-provider plugin release gate now runs validation, pin hashing, and
  subprocesses from a private `git archive HEAD` materialized checkout;
  uncommitted pinned-input edits are refused up front and the checkout is
  revalidated before receipt emission (issue #49).

- MCP tool results decide inline-vs-publish from the caller's
  `result_budget.Budget.per_result_bytes` on both MCP paths — the classic
  `McpClient` and the AgentCore `mcp_result_stream` projector — the same number
  the native tools have used since #41, instead of a private 64KB constant in
  AgentCore that merely coincided with it, and an unconditional inline of every
  response below the classic client's 1MB frame limit (issue #43). `McpClient.callToolBodyAbortable` /
  `listResourcesBodyAbortable` / `readResourceBodyAbortable`,
  `mcp_result_stream.project` and `mcp_runtime.Client.callToolBody` take that
  budget as a required parameter; embedders pass `ctx.result_budget` verbatim.
  This is a breaking signature change for library consumers.

### Removed

- First-class PDF document input is withdrawn (issue #25). Agent Core carries
  cross-format, cross-provider, cross-host input modalities; parsing a
  container format, judging its pages, encryption and structure, and
  attributing budget from that judgement are not Core's job — and a lexical
  scan could not answer those questions correctly anyway, which is how it
  produced three ways to reject a valid document. Removed: the `document`
  block and its neutral IR, `core/pdf.zig`, `supports_pdf_input` /
  `Capability.pdf_input`, the dialect document serializer, transcript and
  checkpoint persistence, `RUN_INPUT_PART_DOCUMENT`, and the headless `--pdf`
  flag. The `Read` tool description stays corrected: it still does not claim
  PDF reading or a `pages` parameter.
  Compatibility: a transcript or checkpoint recorded with a document block is
  refused explicitly rather than partially read — the transcript loader is now
  atomic and reports a dedicated error with an actionable message, and the
  checkpoint decoder reports `UNSUPPORTED` (not `CORRUPT`) for an intact
  checkpoint carrying the permanently reserved block tag `7`, and only after
  its digest has been verified. While the observation channel stays usable, the
  terminal `run_state` snapshot is published exactly once from the Run's final
  result: a post-admission cleanup failure closes it as `poisoned`, an abort accepted from
  the `finalizing` callback is reflected as `aborted` (it used to leave a
  `completed` snapshot beside `STOP_ABORTED`), Runs that never ran the loop — a
  clean failure, a Skill aborted during activation, a synthetic completion —
  no longer stay at `starting`, degraded tool-set observation no longer
  suppresses the closure, and a Host that rejects the terminal snapshot — or
  any callback failure the Session already recorded — fails the Run with the
  recorded callback status and poisons the Session instead of being reported a
  successful Run.
- AgentCore ABI v1 returns to **revision 15**; `RUN_INPUT_PART_DOCUMENT`,
  `MAX_RUN_INPUT_DOCUMENT_DATA_BYTES_V1` and status
  `DOCUMENT_INPUT_UNSUPPORTED` are gone. No bundle was ever published from a
  revision-16 tree (the only release, `0.1.0`, is revision 14, has no assets,
  and no workflow publishes or uploads a bundle), so revision 15 keeps a single meaning and
  the codes need no tombstone. SDK package version returns to `0.2.0-dev`.

### Fixed

- Unhinted `ReadMcpResourceTool` no longer reports a local MCP storage failure
  (`resource_limit` on a full session quota) as `resource_not_found`: the MCP
  client classifies it as `system_error` and the read loop returns it instead
  of trying other servers. Remote errors still fall through to
  `resource_not_found`, which now carries the last server's error detail
  (issue #56).
- A CAS publication failure (a full session quota, for example) no longer turns
  a bounded MCP result into a tool error. All three publishers — the native
  spool, the classic `McpClient` and the AgentCore projector — share
  `result_budget.retainInlineAfterFailedPublish` and keep the bytes inline up to
  their own materialization ceiling (64KB for the two that would have to read
  from disk, the 1MB frame limit for the classic client, which already holds
  the bytes), so the conversation projection renders its bounded head/tail
  envelope with `storage_error` exactly as it did before the threshold change.
- AgentCore's request preflight (`canonicalRequestBytes`) charges image tool
  results as native bytes only when the configured model accepts image
  input; on a text-only route the estimate is exactly the placeholder request
  the serializer sends. Previously the full base64 length was added back
  unconditionally, so a few large image results on deepseek-chat / glm-5.2
  returned `checkpoint_budget_exhausted` for a request of a few hundred
  bytes, and repeated it on every later run because those results are
  non-trimmable.
- Image results now have a wire-size safety net: they bypass the byte
  budgets, so five parallel 3.75 MB pictures could produce a request no
  provider accepts. `types.MAX_IMAGE_RESULT_BYTES_PER_REQUEST` (16 MiB) caps
  the base64 image bytes per request: the projection spills the largest
  images of the current turn beyond the cap into artifact envelopes, and the
  agent loop stubs the oldest already-delivered image results before each
  request until the history fits (first-class user images count against
  the allowance and a fresh tool turn is projected against what they leave;
  the block-level watermark is persisted in the transcript, so a resumed
  session trims exactly the pictures earlier requests delivered natively and
  reports explicitly when only non-trimmable images exceed the cap).
  Gemini 3 function responses embed only
  PNG/JPEG/WebP; `image/gif` results now go out as a sibling `inline_data`
  part instead of being rejected. The stream handle reports the exact
  tool_use ids whose image went out as a placeholder, so a plugin dialect
  that serializes some MIME types natively and refuses others no longer pins
  the natively-sent pictures.
- OpenAI chat/completions and Gemini dropped every text block that shared a
  message with tool results: the PostToolUse `additionalContext`, the
  verification checkpoint, the requirement-ledger prompt and similar host
  text that the agent loop appends to the tool-result user message never
  reached those providers (Anthropic and the OpenAI Responses protocol were
  unaffected). The chat serializer now re-sends that text as a user message
  after the tool messages (or as the last part of the image follow-up
  message), and Gemini appends it as trailing text parts of the same user
  content. Covered by serializer tests and by the hook-pipeline component
  test, which now asserts the context on the wire.
- The image projection exemption (issue #26, below) is covered end to end by
  an agent-loop test that reads an 80 KiB-base64 PNG through the real `Read`
  tool and asserts the image block on the wire, and the same exemption now
  also holds at the two other layers that rewrite a tool result before
  serialization: microcompact no longer clears an image
  result under the recent-N pressure valve (a `Read(image)` with two parallel
  siblings was cleared before the provider ever saw it), and the AgentCore
  `ToolEnvironment` no longer promotes an image above `tool_result_cap_bytes`
  to an artifact (the payload cap is charged at the vision estimate, the
  durable budget at the real bytes). In exchange the shared predicate
  `extractImageResult` only accepts the canonical Read shape: allowlisted
  media type (`image/png|jpeg|gif|webp`), standard base64, at most
  `MAX_IMAGE_BYTES` of payload, exactly the three keys in any order with only
  whitespace after the closing brace, so a plugin cannot obtain an unbounded
  exemption by prefixing arbitrary output with `{"type":"image"`. `result_projection.Stats.projected_bytes` stays a
  real byte count; the turn-budget decision moved to a new `budget_bytes`.
  The predicate is structural (any field order, standard JSON whitespace,
  exactly the three keys, raw content bounded by `MAX_IMAGE_RESULT_BYTES`),
  so surrounding whitespace cannot smuggle an oversized payload past the
  budget and a JSON serializer that does not escape `/` still produces an
  image. Microcompact protects only images that have not yet been delivered
  to the provider, where delivery is an explicit per-message watermark
  (`Message.delivered`) advanced by the agent loop once the provider has
  accepted a request for streaming — and, for messages holding an image
  result, only when the serializer actually sent native image parts (a
  non-vision model only received the placeholder; the serializer reports the
  affected tool_use ids back on `StreamHandle.image_placeholder_ids`, and the
  flag lives on each tool_result block) — never inferred from a locally
  appended assistant message; delivered
  images clear like any result, so the pressure valve keeps working on
  image-heavy history, and images are never truncated. AgentCore `settleSuccess` now counts live
  sibling reservations against the hard budget, so an inline image whose
  durable bytes exceed its own reservation is refused instead of consuming
  the space a parallel tool had already reserved.
- Transcript resume no longer treats a failed `read` as end-of-file: `EINTR` (a
  Ctrl+C or terminal resize during `/resume`) is retried, and any other read error
  makes `loadTranscript` and the compact-state meta loader fail with `ReadFailed`
  instead of silently restoring a truncated or empty history. The `/resume`
  listing keeps skipping a session whose `meta.json` cannot be read. Surfaced by
  the Codex cross-review on #46.
- Restoring a persisted compact projection is all-or-nothing: `restoreCompactState`
  allocates the summary before touching either field, so an allocation failure
  during resume leaves a genuine full replay rather than an advanced boundary with
  no summary (and no dangling summary pointer).
- A KG client that owns no Store can no longer create one (issue #30).
  `KgClient.store_path` was a single `[]const u8` carrying two meanings — a
  real path under the CLI transport, and the marker `"daemon-owned"` under the
  daemon transport, meaning *this client owns no Store*. Nothing in the type
  stopped the marker from reaching a call that treats it as a path, and
  `cloneForThread` did exactly that: it guarded on `transport == .daemon`,
  while the marker is set for `.daemon` **and** `.unconfigured`, so an
  unconfigured parent fell through to the CLI reconstruction, which re-resolved
  a real `bin_path` and then ran `tinykg init daemon-owned`. Because the marker
  is relative, the Store materialised in the process's current directory — for
  the TTY e2e suite, the git worktree, as untracked `daemon-owned/` and
  `daemon-owned.tinykg-daemon.lock` that no `.gitignore` rule covered.
  The field is now `store: StoreRef`, a union of `.owned` (an absolute path)
  and `.unowned`; `argvSlot()` serves the argv slot the wire protocol
  reserves, and `fsPath()` returns an optional that every filesystem call must
  unwrap. A relative store path from config or `METACODES_KG_STORE` is
  completed against `home` rather than taken as given, so no configuration can
  steer the Store — or the five sibling artifacts derived from it — into the
  current directory. **Breaking for source-level consumers:** `store_path` is
  replaced by `store`.
- `zig build --build-file control-plane/build.zig rule-check` passes again. It
  demanded that every discovered test be imported into `tests/integration_suite.zig`
  while build.zig panics if a *dedicated* test appears there, so the reported
  omission was unfixable as stated: satisfying the rule aborted the build and
  took seven rules down with it. The sensor kept a hand-written copy of
  build.zig's `aggregate_test_exclusions` that had gained neither the second
  entry nor a way to notice; it now parses that list from build.zig, and
  additionally requires each excluded test to have its own `root_source_file`,
  so being excluded from the aggregate means having a home rather than merely
  having a file.
- The OpenAI Responses protocol now replays reasoning items across tool
  continuations (issue #23). Requests use `store:false`, so the server keeps no
  copy of the response and reasoning context survives only if the client sends
  the server's own `reasoning` items — `id`, `summary`, `encrypted_content` —
  back verbatim; previously they were parsed away and the next request carried
  only the function call and its result. Items are captured from
  `response.output_item.done` **and** from the terminal response's `output`
  array, deduplicated by id so an item present in both is replayed exactly
  once, and emitted first among their message's `input` items, matching the
  server's own output order. Replay is model-scoped: after a mid-session model
  switch the stale encrypted state is dropped rather than sent to a model that
  would reject it. Reasoning items persist through the JSONL transcript and the
  AgentCore checkpoint (block tag 6). A conversation without reasoning items
  serializes byte-identically to before.
- Image tool results are no longer spilled into artifact envelopes before the
  dialect layer can serialize them (issue #26). `result_projection` rewrote any
  tool result above a `clamp(window/8, 8 KB, 64 KB)` threshold, while the
  `Read` tool accepts images up to 3.75 MB — so essentially every real
  screenshot became an envelope and the native image serialization added in
  #24 never ran on it, on every provider. Image-shaped results (detected with
  the existing `dialect.extractImageResult`, not a second sniffer) are now
  exempt from byte-length spilling in both projection passes, and the per-turn
  budget charges an image at `IMAGE_TOKEN_ESTIMATE` instead of its base64
  length, so one screenshot no longer evicts unrelated tool results. Images
  stay bounded by `MAX_IMAGE_BYTES`, and non-image results project
  byte-identically to before.

- Image tool results (the `Read` tool's
  `{"type":"image","media_type":...,"data":...}` form) are now serialized
  natively on every protocol family instead of being passed to the model as a
  multi-megabyte base64 text string on OpenAI and Gemini. Vision models get
  the image itself: OpenAI chat/completions sends a short pointer in the tool
  message and the image in an immediately following user message (tool
  message content officially accepts text only); the OpenAI Responses
  protocol sends `function_call_output.output` as an official `input_image`
  parts array; Gemini 3 uses the official multimodal function response
  (`functionResponse.parts[].inlineData`), older Gemini models get a sibling
  `inline_data` part in the same user turn. A model without vision gets a
  short explicit placeholder — never the raw base64 — including text models
  behind Anthropic-compatible gateways, which previously received an `image`
  source block they reject. Non-image tool results and Claude vision
  serialization stay byte-identical (prompt-cache prefixes unaffected).

### Added

- Provider profiles, model offers, and a UI-independent runtime control plane
  (issue #16, delivery slice P0 plus the Z.AI GLM Coding Plan provider).
  `ProviderProfile → ChannelDescriptor → ModelOffer → RuntimeSelection`
  replaces "a model name identifies the route": relays, regions, plans,
  accounts, and BYOK bindings now produce distinct offers for the same visible
  model, and `OfferId` is a domain-separated digest over the normalized stable
  binding so a metadata refresh moves `offer_revision` without moving a pinned
  selection. Adding a vendor is one `src/provider/profiles/<vendor>.zig` file
  plus one line in `BUILTIN_PROFILES`; the transport is selected by the offer's
  protocol, which retires `main.zig`'s model-name prefix guessing for every
  session that names a provider. New CLI flags `--provider`, `--channel`, and
  `--offer`; a model matching several routes reports the candidate offer ids
  instead of guessing, and a `--base-url` override is validated against the
  profile and route policy before any request URL is constructed. Ships
  `metask`, `openai`, `gemini`, and `zai-coding-plan` profiles — the last with
  all four documented China/global × OpenAI/Anthropic-wire routes, its own
  credential kind, `ZAI_API_KEY`/`GLM_API_KEY`/`Z_AI_API_KEY` aliases, and a
  forbidden-path rule that makes silent fallback to the general
  `/api/paas/v4` surface unrepresentable. Credentials become typed, secret-free
  `CredentialRef`s resolved in provider scope, so a Metask key can no longer
  authenticate an OpenAI or Z.AI route; the transports materialize a
  provider-declared `AuthScheme` (bearer, `x-api-key`, custom header) instead of
  a hard-coded bearer header. Metadata is conservative throughout: distinct
  context/input/output limits with fail-closed admission, tri-state
  capabilities, `unknown` (never zero) prices, and per-field provenance.
  `~/.metacodes/config.json` gains a schema-versioned, monotonically revisioned
  provider map written under a cross-process lock via temp-file + fsync +
  rename, with idempotent retries and deterministic revision conflicts. See
  [doc/PROVIDER_OFFER_ARCHITECTURE.md](doc/PROVIDER_OFFER_ARCHITECTURE.md),
  including its explicit list of deferred slices.
  Endpoint policy refuses two whole classes of URL rather than pattern-matching
  them: a percent-encoded host or path (a substring rule over encoded bytes is
  not a rule while the server still decodes it) and any URL carrying userinfo
  (that string becomes `ModelOffer.endpoint_ref` and flows into `model.list`,
  events, and setup output, none of which redact it). The control plane guards
  its mutable state and hands `model.list` results into a caller-owned buffer,
  so two clients cannot invalidate each other's page; `events.replay` copies
  under the lock. `config_store` is the single authority for `config_revision`
  — the kernel mirrors it through `adoptConfigRevision` rather than keeping a
  second counter — and idempotency keys are a bounded ring, so a retry is still
  recognized after other commits have landed.

- Cross-UI model picker, durable selection at startup, and built-in pricing
  (issue #16, further P1 slices). `Ctrl+O` and `/model` open one picker —
  provider → canonical model → channel/offer → options → commit — that reads
  offers from the control plane and mutates only through it. Offers are grouped
  by canonical id, never by visible name, so two channels serving "GLM-4.6"
  over different protocols, regions, or prices stay separate rows showing their
  endpoint, wire model id, limits, price, and health. The picker is modal for
  the keyboard and not for the session: typing filters, the draft in the input
  box is untouched, a reply keeps streaming, and a mid-stream commit takes
  effect on the next turn. Session is the default scope and `Tab` cycles to
  `global`/`once`, so a durable write is always an explicit act the footer
  spells out before Enter. Transcript viewing moves to `Ctrl+X Ctrl+O` — same
  letter, on the existing `Ctrl+X` prefix — with `/transcript` as the
  documented equivalent; TTY regressions cover both paths, including their
  Kitty CSI-u forms. `/model use <id>` now resolves against the offer catalog
  first, so a model served by another provider or protocol switches in place; a
  name carried by several routes reports their offer ids instead of guessing,
  and an offer id is accepted verbatim. `/models` keeps account-key selection,
  which is a credential choice rather than a route.
  A selection committed with `global` scope is now read back at startup:
  `applyPersistedGlobalSelection` applies it before model-name inference, and a
  stored pin the catalog no longer offers is a startup error naming the offer
  and the way out — never a silent fallback to another vendor. Session scope
  gets its own document and its own file (`<session>/runtime-selection.json`)
  rather than sharing the global key, so one session's choice cannot become
  everyone's. The `metask` profile ships a real quote derived from
  `util/pricing.zig` — the same table `/cost` reports with, asserted equal
  field by field — while `zai-coding-plan` deliberately stays `unknown` because
  a Coding Plan subscription is not billed per token. `Quote` gains a cache-write
  rate so an estimate over a cached turn is not silently low.
  New gate `zig build test:picker` compiles the picker from a root reaching the
  provider kernel and the terminal theme and nothing else.

- User-defined providers (issue #16, P1). A `custom_providers` section in
  `~/.metacodes/config.json` defines provider instances that go through the same
  registration and validation as a built-in profile, so the picker, `--provider`,
  `model.list`, `quote.estimate`, and token admission treat them identically.
  The schema is declarative and cannot execute anything: there is no field for
  code, a callback, a shell command, or a request template, and unknown keys are
  ignored rather than interpreted. A protocol is a *wire* plus an optional
  request path — what relays and gateways actually differ by — so a relay needs
  no adapter, while a genuinely novel wire is rejected rather than guessed.
  Declared limits, capabilities, prices, and controls carry
  `user_config` provenance and a configured price is marked estimated, because a
  number the user typed is a declaration and not a vendor observation. New
  `--check-providers` dry run validates the configuration and prints every route
  it produces — provider, channel, protocol, endpoint, wire model id, context,
  price — with no credential resolved and no request URL built.

- Provider catalog adapters and the events they enable (issue #16, P1).
  `src/provider/openrouter.zig` parses model and endpoint documents
  *separately* — a model with three endpoints becomes three offers, because a
  model name is not a route — and merges them so an endpoint's own values win
  while an absent one inherits with `inherited` provenance instead of becoming
  free or unlimited. An endpoint that never reported a status has `unknown`
  health, not healthy; a price string that is not a number is an error, not a
  zero. Provider preferences compile into `RoutePolicy` with `only`/`ignore` and
  the numeric ceilings as hard constraints and `order`/`sort` as preferences
  that never reject, and `PriceConstraint` gained per-direction ceilings because
  a router's price limit is per direction. Router metadata folds usage, cost,
  latency, and fallback attempts into the `ActualRouteEvent` the kernel derived
  without rewriting what was requested. Ingesting a catalog moves the catalog
  revision and emits `catalog.updated`, `pricing.updated`, and
  `provider.degraded`; `auth.changed` and `credential.expiring` gained kernel
  producers. Catalogs are named by a `provider_catalogs` section in
  `config.json` and read from disk, so no transport dependency enters the
  provider subsystem.

- Provider-scoped OAuth lifecycle (issue #16, P1). `provider/oauth.zig` runs
  refresh, single flight, and rotated-refresh persistence for any profile that
  declares an OAuth credential kind and a token endpoint — OpenAI and Codex
  first; Metask keeps its historical `core/auth.zig` path byte for byte. N turns
  discovering an expired token at once perform exactly one refresh, because with
  a rotating refresh token the losers of that race would present a token the
  server already invalidated. The rotated token is persisted atomically (temp
  file + fsync + rename, 0600) *before* it becomes the live one: a provider that
  rotated has already killed the old token, so "used but not saved" locks the
  user out while "saved but not yet live" is recovered by the next load. Refresh
  triggers a margin before expiry, since a token that expires mid-flight fails
  the request it was attached to, and `invalid_grant` is terminal rather than a
  transport error a retry loop would chew on. The module performs no I/O — the
  exchange is a function pointer, with `api/oauth_exchange.zig` as the
  production `refresh_token` grant — so every lifecycle test drives a fake and
  none needs a network. `metacodes login --provider <id> --oauth-token-json
  <file>` imports the first token into that provider's own store.

- Selection scope, auth-scheme inheritance, and the query-auth decision
  (issue #16). A `session`-scoped commit is now written to the session's own
  `runtime-selection.json` and restored by `/resume`; because session scope is
  narrower than global, a resumed session continues on the route it was using
  rather than whatever became global meanwhile, and a stored route that no
  longer resolves is reported instead of silently replaced. The resolved route's
  auth scheme now reaches swarm teammates and `AgentSession` as well as `App`
  and background subagent jobs — a worker sending bearer at an `x-api-key`
  endpoint has the right key and the wrong header — and a route switch moves the
  swarm context with it so a teammate spawned afterwards cannot dial the
  previous provider. `AgentJobRegistry.setRoute` moves key, endpoint, transport,
  and scheme together for the same reason.
  `AuthScheme.api_key_query` is **removed** rather than implemented. A secret in
  a query string lands in server access logs, proxy logs, and referrer headers,
  and it would flow into the endpoint strings this subsystem already refuses to
  let carry credentials — the endpoint policy rejects userinfo URLs for exactly
  that reason.

- Credential pools: several accounts per provider, each its own route
  (issue #16, P2). A `credentials` list on a configured provider declares
  accounts **by reference** — id, environment-variable name, kind, priority —
  so no secret enters `config.json`, which several tools read and which is not
  mode 0600; a literal `secret` key is rejected at parse time. A bound
  credential participates in the offer id, so each account becomes its own offer
  and appears as its own row in the picker with an `account=` column. That also
  removes the need for a separate credential stage: the accounts already are
  offers. Because the offer names the credential, binding uses that member
  rather than the pool's highest-priority one — resolving to a different account
  would make the offer id identify a route the request does not take. Selection
  among unbound members is deterministic (priority, then id) so configuration
  order cannot make a failover irreproducible, and members that are invalid,
  cooling down, expired, or empty are skipped. `noteFailure` maps a
  provider-classified failure to the right state: a rate limit earns a cooldown,
  an authentication failure marks the credential invalid, and a transient
  network error changes nothing. The pool is consulted after every existing
  source, so a single-credential setup resolves exactly as before.
  `credential.expiring` and `auth.changed` now have producers on the OAuth path,
  which is the only thing that knows a credential's expiry.

- TinyKG decision audit plane (issue #16). Control-plane events are projected
  into an append-only record under `metacodes/provider-decisions` at the turn
  boundary — accepted and rejected selections with the catalog and config
  revisions that make them reproducible, actual routes with fallback attempts
  and cost/latency aggregates, failovers, catalog and pricing refreshes, and
  credential status changes. `provider.degraded` health samples are deliberately
  excluded: the requirement names high-frequency observations as something that
  must not accumulate in the graph. The projection is safe by construction —
  event payloads are ids and enums with no free-form field — and a test asserts
  no recorded line contains a quote, a URL, `Bearer`, or `sk-`. The plane is
  optional: nothing on the request path calls it, and a TinyKG outage is counted
  rather than propagated into routing.

- Catalog fetching and learned credential failover (issue #16). Provider
  catalogs may now be fetched (`models_url`, `endpoint_urls`, optional
  `credential_env`) as well as read from disk, with `/providers refresh` driving
  it; a refresh that fails leaves the previous catalog in place, because a stale
  catalog is a better answer than an empty one and every pin stays resolvable.
  The fetch lives in `api/catalog_fetch.zig` rather than in the provider
  subsystem, which must not depend on a transport. `/providers` also lists every
  route with its account, context, and price. Credential failure state is now
  learned and durable: a rate limit records a cooldown and an authentication
  failure records an invalidation, through the same lock, revision, and atomic
  write as every other mutation, so the next process skips the credential
  instead of rediscovering the limit by hitting it. The class is the provider's
  own classification, and a transient network failure records nothing.

- Local route aliases (issue #16, P2 follow-up). `AliasEntry` was a declared
  record with no producer or consumer; `/alias` now creates, lists, resolves,
  and removes them. A **pinned** alias stores the offer and revision and means
  the same route across catalog refreshes — reporting an error when that route
  is gone rather than resolving to a neighbour, because a pin that quietly moves
  is not a pin. A **floating** alias stores the selector and re-resolves, and
  records what it landed on so a route stays attributable after the fact; a
  selector matching several routes is an error listing the candidates, not a
  guess. Either policy produces a *pinned* runtime selection, since the alias
  already decided and leaving it auto would let it re-resolve mid-turn against a
  catalog the user never saw.

- Provider lifecycle through the control plane, and a five-vendor capability
  fixture (issue #16). `/providers enable|disable|remove <id>` manages a
  provider instance without editing `config.json` by hand; disabling preserves
  its configuration and credential references — the difference from removing it
  — and excludes it from the *catalog*, so "disabled" is true in the picker,
  `model.list`, and `--provider` at once instead of being re-checked at three
  call sites. A new capability-matrix fixture declares DeepSeek V4, GLM-5.3,
  Kimi K3, GPT-5.6, and MiniMax M3 with timestamped, provider-declared
  capabilities and four different control vocabularies, and asserts what no
  name-inference rule could get right: reasoning supported / unsupported /
  unknown across three models, GLM's peer `reasoning_content` as a separate
  capability, a latency tier on one model and a service tier on another, and
  channel-specific limits narrowing a model's own. New L2 coverage proves a
  control change alters the bytes actually sent (and that leaving it unset
  smuggles no default onto the wire), and that a provider's opaque control
  metadata round-trips through `model.list` into the picker without any core,
  TUI, or Web change.
  A committed route is also broadcast on the existing UI event stream as a
  `config_changed` → `route` event carrying provider, channel, protocol, wire
  model id, offer id, credential reference, and scope — the model name alone
  would announce a change an out-of-process client cannot tell apart from
  another, since one visible name can come from several providers, channels,
  protocols, and accounts. The credential reference travels; the secret does
  not.

- AgentCore ABI v1 revision 15: `session_run_input` gains
  `RUN_INPUT_MULTIMODAL` — an ordered `RunInputPartV1` array of text and
  base64 image parts (per image capped at the Read tool's 3.75 MB raw limit,
  total bounded by the 16 MiB input cap) that becomes one first-class
  multimodal user record with the exact-reservation admission invariant, full
  checkpoint/restore round-trip, and a pre-admission image-capability
  preflight returning the new status
  `METASK_AGENTCORE_STATUS_IMAGE_INPUT_UNSUPPORTED` (28) before any Provider
  request. C header, Zig SDK (`runMultimodal`, `textPart`/`imagePart`), Rust
  bindings, and both source-free consumers move to revision 15 atomically;
  source embedders get `AgentSession.runUserParts` /
  `Conversation.appendUserParts` and the example gains `METACODES_IMAGE`.
  Fixed en route: the provider-neutral canonical request projection (durable
  budget accounting, journal request identity, token estimates) no longer
  re-applies per-model image capability — previously any image run on a
  vision model whose name lacks `claude` (every OpenAI/Gemini model) failed
  inside accounting with `ImageInputUnsupported` before the real request was
  sent (`json.serializeCanonicalRequestProjection`).
- Model tiers (issue #11 core-side fix): subagent/skill model pins and
  `/model` now resolve tier names — `low`/`mid`/`high`, with legacy aliases
  `haiku`/`sonnet`/`opus` mapping to the same tiers — against a per-provider
  table in `~/.metacodes/config.json` (`model_tiers`, keyed by provider kind,
  each tier an optional `{model, effort}`). An unconfigured tier inherits the
  session model/effort; the hardcoded alias→Anthropic-ID map is gone, so a
  tier or alias can never inject a cross-provider model ID — the mechanism
  that made Explore subagents send `claude-3-5-haiku-20241022` to
  OpenAI-compatible relays and fail with an opaque 503 while the parent
  session worked. The built-in `Explore` agent now pins tier `low`
  (previously `haiku`); `/model <tier>` applies the configured tier model and
  keeps the existing cross-provider guard for unresolved literals. Tier
  `effort` rides the existing per-family dialect translation, which now also
  covers MiniMax: M3 gets the native three-state
  `thinking:{type: disabled|adaptive|enabled}` mapping (compat
  `reasoning.effort` strings are accepted upstream but do not tune depth, so
  they are not sent), and M2.x — where thinking is always on — sends only
  `reasoning_split:true` so reasoning arrives as `reasoning_content`.
  OpenAI/Anthropic/GLM/Kimi/DeepSeek translations were already built in.

### Changed

- Language server integration is **on by default**; the new `--no-lsp` turns it
  off (issue #17 follow-on). `--lsp` still works and now simply reasserts the
  default, so existing command lines keep running; the last of `--lsp` /
  `--no-lsp` on the line wins.
  - *Why flip it.* Since `1515b34` removed tree-sitter, `CodeMap`,
    `FindSymbol`, `Read(outline: true)` and Edit/Write post-write diagnostics
    all source symbols from LSP, so an opt-in flag meant the default
    configuration ran four features in a degraded state. The flag was also a
    redundant second gate: the real gate is and remains runtime — a registered
    server for the extension, its binary actually installed, the file inside a
    git workspace, a `root_marker` hit — followed by lazy spawn keyed by
    `server_id+root`, a 10-minute idle reaper, a client-count ceiling and the
    broken-set. On a machine with no language server installed, enabling it
    starts no process at all.
  - *What it costs.* The one newly-involuntary path is post-write diagnostics.
    Measured on this repository with zls: 112 ms cold, 52 ms warm per write.
    The 14 s/26 s constants in `lsp/service.zig` are ceilings for heavier
    servers, not typical values; the disk write itself is never blocked and the
    wait is Ctrl+C-interruptible.
  - *Escape hatch reaches subprocesses.* `--no-lsp` propagates to
    out-of-process teammates, which would otherwise start their own servers
    against the lead's explicit choice.
  - *Not closed by this change.* Subagents still run without LSP:
    `agent_loop.Options.lsp` is deliberately not threaded into child loops
    because `lsp/client.zig` requires `sendRequest`/`sendNotification` from a
    single caller thread while subagents run on background threads, so lifting
    it needs send-side serialization in the Client, not a one-line passthrough.
    For the same reason independent sessions cannot share a `Service`, so each
    out-of-process teammate and each `--serve-multi` daemon session starts its
    own servers; `--no-lsp` is the lever meanwhile.
  - *Rejected.* Enabling by project size — `root_markers` already encode "this
    is a real project", and large trees are exactly where indexing is most
    expensive, so size-as-eagerness is backwards. Auto-installing language
    servers — it contradicts the repository's binary policy, spans six
    unrelated install channels, would execute npm `postinstall` outside the
    permission and sandbox layers, and a version-mismatched server is worse
    than an absent one because nothing signals the error.

### Fixed

- `~/.metacodes/config.json` writes no longer delete other writers' keys. The
  config writer serialized only its own five fields, so any theme change
  silently dropped `mcp_servers`, `permission_rules`, and `model_tiers`. It now
  merges through an order-preserving JSON merge, refuses to overwrite a document
  it cannot parse, and treats a failed read as an error rather than as an empty
  document — descriptor exhaustion or a transient I/O error would otherwise
  truncate the whole file.

- The language server binary lookup is platform-correct, so the LSP subsystem
  is no longer unconditionally dead on Windows. `lsp/servers.zig`'s `which`
  hardcoded three POSIX assumptions — split `PATH` on `:`, join with `/`,
  test executability with `access(X_OK)` — and every one of them fails on
  Windows: `C:\bin;C:\other` split on `:` yields `C`, `\bin;C`, `\other`
  (none of them a directory), and executability there is decided by the
  `PATHEXT` extension list while every registered `ServerDef.binary` is an
  extensionless name (`zls`, `gopls`, `clangd`). Both consumers flow through
  that one function, so they failed together: `Service.getOrSpawn` could never
  start a server, and the issue #17 capability gate `servers.binaryAvailable`
  reported "the '<binary>' language server is not installed (not found in
  PATH)" for every language even when it was installed. This predates issue
  #17; that work only made the failure legible. The lookup now lives in the
  portable layer as `platform.exe_lookup` (separator, joiner, `PATHEXT`
  probing with the cmd.exe default list, quoted `PATH` segments,
  drive-relative names, and no extension appended to a name that already
  carries one), and `which` is a one-line delegation. `realProbe` also stops
  accepting a *directory* as an executable, which plain `access(X_OK)` did on
  POSIX. Empty `PATH` segments are still skipped rather than searching the
  working directory, which POSIX would allow but is a PATH-injection surface.
- `zig build test:platform` ran **zero** tests, and `windows:gate` depends on
  it — so the "Native Windows platform gate" step was passing vacuously for
  its entire unit-test half. `src/platform/platform.zig` aggregated the
  submodules as `pub const x = @import(...)` with no `test` block referencing
  them, and Zig only collects tests from files it analyzes. Adding the block
  turns up 52 tests (43 pass / 9 environment-skipped) that had never run. The
  LSP suite (`test:lsp`) now also runs on that gate, and the workflow's path
  filter covers `src/lsp/**`, since server lookup is native-platform logic.
  Independently of that gate, `ci.yml`'s per-module `zig test
  src/platform/<module>.zig` loops — the unfiltered ones that run on every PR,
  on POSIX and on the Windows runner — now include the new module, so the
  Windows-semantics assertions run on both.

- The new lookup's parsing is a pure function over an explicit `Style` plus a
  supplied `PATH`/`PATHEXT` string, so Windows semantics are asserted on
  **every** host — including the regression case that splitting `C:\bin;C:\other`
  on `:` shreds it — instead of behind a `SkipZigTest` on non-Windows machines.
  `lsp/servers.zig`'s own `which` test likewise stopped skipping on Windows and
  now asserts against `cmd`/`cmd.exe` there and `sh` on POSIX.
  Windows support for the subsystem as a whole is **not** claimed: process
  spawn, pipes, polling and termination already have real Windows
  implementations, but `workspace.isInsideWorkspace` only accepts `/` as a
  path boundary (so every file is judged outside the workspace),
  `client.pathToUri` emits `file://C:\proj\a.zig` where LSP requires
  `file:///c%3A/proj/a.zig`, and `CreateProcess` cannot launch the `.cmd`
  shims npm installs for `typescript-language-server`. Those three are
  enumerated in the status table at the top of `src/lsp/lsp.zig`, which is the
  single place that states Windows readiness.

- Symbol capability gaps no longer masquerade as "symbol not defined"
  (issue #17). `FindSymbol` returned a bare `[]` whenever `--lsp` was on but
  the language server binary was missing, because the *decide* predicate
  (`symbol_provider.hasSymbolsFor`) consulted only the compile-time
  `SERVERS` extension table while the *use* predicate
  (`lsp.Service.getOrSpawn`) additionally resolved the binary, spawned it,
  and consulted the broken-set — a two-state type (`!Symbols`) squeezing a
  three-state reality. The shape was inherited from the tree-sitter era, when
  statically linked grammars made "extension registered" equivalent to
  "capability available"; commit `1515b34` changed the dependency to an
  external runtime process without updating the capability contract.
  The predicate is now single-sourced and runtime-aware
  (`lsp.servers.binaryAvailable`), and the symbol path carries an explicit
  third state (`lsp/capability.zig` `Unavailable{reason, detail}`,
  `symbol_provider.Outcome`, `lsp.Service.fetchSymbols`) with one shared
  wording table. `FindSymbol` now appends a qualifier naming the missing
  binary (and flags partial results when only some candidate files were
  skipped), `CodeMap` prints the specific reason instead of `(no symbols)`,
  and `Read(outline: true)` explains why it fell back to a full read rather
  than degrading silently. When a scan spans several languages the reported
  reason is the most *actionable* one rather than the first encountered — rg
  walks in parallel, so a README that merely mentions the name could otherwise
  make the answer "no language server is registered for this file type" and
  bury the "pyright is not installed" that the caller can act on. The
  per-file capability answer is memoized for the duration of one scan
  (`symbol_provider.CapabilityCache`, caller-owned, no global state): the
  predicate costs a PATH scan — measured at 36–43 µs with a 30-entry PATH —
  and FindSymbol asks it once per candidate file, up to ~3200, for at most
  seven distinct answers. Regression tests cover the **server-absent** side
  unconditionally — synthetic `ServerDef`s with absolute-path binaries make
  that side reachable on any machine, replacing the
  `if (which("zls") == null) return error.SkipZigTest` pattern that had
  skipped exactly the half where the defect lived.

## 0.1.0 — 2026-08-29

### Security

- Third-party GitHub Actions are pinned to full commit SHAs, and the Windows
  Rust bootstrap downloads a version-pinned `rustup-init` verified by SHA-256
  before execution — the action set and the installer are no longer mutable at
  fetch time. (The Rust `stable` toolchain itself stays rustup-managed behind
  the presence guard: it installs once and is not re-resolved per run.)
- `scripts/verify_tinykg_binary.py` now inventories `vendor/tinykg/bin/`:
  an executable not declared by the manifest fails the gate (per-binary
  hashes cannot see extra files).
- The rule-control telemetry artifact no longer records the runner's absolute
  workspace path, and feedback child processes run with secret-named
  environment variables removed (name denylist: `*API_KEY*`, `*ACCESS_KEY*`,
  `*PRIVATE_KEY*`, `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*CREDENTIAL*`), so
  echoed child environments do not carry those variables into uploaded
  artifacts.
- Prepared the extracted history for removal of a legacy hard-coded provider token
  before any remote publication. Public visibility remains blocked on an
  independent full-history scan and owner-selected project license.

### Added

- The AgentCore bundle now ships ripgrep as a manifest runtime asset
  (issue #8 follow-up): `vendor/ripgrep/` grows a TinyKG-style manifest-pinned
  cross-platform set of upstream official 14.1.1 release binaries
  (macos-aarch64/x86_64, linux-x86_64 musl static, the existing
  windows-x86_64; `aarch64-windows` explicitly maps to the x86_64 executable
  via Windows-on-ARM x64 emulation), verified fail-closed by
  `scripts/verify_ripgrep_binary.py` (SHA-256, format magic, exact `bin/`
  inventory) in CI. `zig build agentcore:bundle` stages the target's binary as
  `bin/rg[.exe]` (SHA-verified by `scripts/stage_ripgrep_binary.py`), records
  it in the manifest `files` allowlist plus a new `runtime_assets` declaration
  (name/version/revision/path/upstream/license/role), and ships the MIT text
  as `bin/ripgrep-LICENSE-MIT`; the source-free consumer validates the asset
  hash and declaration, and a target with no vendored ripgrep fails bundle
  assembly. The toolchain resolver's stale `./vendor/ripgrep/rg` fallback now
  points at the real per-target vendored binaries, so dev/CI checkouts resolve
  rg without a system installation.
- UI-neutral session command surface (issue #3): all raw input now flows
  through one typed pipeline (`session_intent.parse` →
  `SessionService.dispatch` → `RunPlan`), shared verbatim by the terminal
  REPL, `--web`, and the daemon. Web/daemon gain `/commit` `/review` `/init`
  `/retry` `/mode` and `!cmd` over `POST /command` (single- and multi-session
  daemons previously answered 501; they now serve the rich `/state` snapshot
  too), the REPL gains `/mode [name]`, and run-option assembly collapses into
  one canonical `session_service.buildRunOptions` — fixing silent capability
  loss where skill-triggered and injected runs were missing
  agents/skills/MCP/cron wiring, and web runs were missing
  LSP/swarm/background-request wiring. Locked by
  `tests/component/session_api_parity_test.zig`.
- Explicit OpenAI Responses API support: `--openai-protocol
  chat_completions|responses` (alias `chat`; env `METACODES_OPENAI_PROTOCOL`)
  selects the OpenAI wire protocol — never inferred from `--base-url` or the
  model name, and invalid values fail closed. `responses` speaks
  `/v1/responses`: typed SSE events (`response.output_text.delta`,
  `response.output_item.added`, `response.function_call_arguments.*`,
  `response.completed`/`incomplete`/`failed`), `input` items with
  `function_call`/`function_call_output` call_id round-trip, top-level
  `instructions`, flat tools, `reasoning:{effort}` (capped at `high`), and
  `store:false`. Subagents and teammates inherit the parent's protocol choice.
- `metacodes --version` prints `metacodes <semver>`; help banner now names the
  project instead of the legacy internal product name. The semver has one
  in-source authority (`src/version.zig`, consumed by the CLI, `lib.VERSION`,
  and the MCP clientInfo handshake), and `zig build test` asserts the real
  binary's `--version` output against `build.zig.zon` end to end.
- `scripts/eval/plugin_release_gate.py --refresh-implementation-fingerprint`:
  the supported repin path after intentional changes to pinned implementation
  files (previously a hand-patched hex edit); validate paths stay fail-closed.
- `scripts/check_doc_links.py` runs over git-tracked markdown, understands
  link titles/angle destinations and CommonMark fence pairing, and is wired
  into `scripts/test_all_gates.sh` and the AGENTS.md pre-submit list, not just
  CI.
- [ROADMAP.md](ROADMAP.md): project status tracked as milestones with exit
  criteria and evidence links.
- [doc/BENCHMARKS.md](doc/BENCHMARKS.md): consolidated benchmark index —
  local performance gates, internal paired evidence, and the external
  WorkBuddy-Bench mainline with ladder status.

### Changed

- `tools.ToolDispatcher` now resolves every per-name execution metadata query
  through one required `metadataFn` returning `?ToolMeta` (executor kind,
  permission category, replay declaration, prefetch flag); the five per-field
  callbacks (`prefetchSafeFn`/`hostSyncFn`/`builtinFn`/`categoryFn`/
  `replayDeclarationFn`) are removed. Dispatch and metadata share one entry
  lookup, so builtin identity, classification, replay and scheduling flags can
  no longer drift apart across the AgentCore wrapper layers
  (budget/Skill/MCP). Consistency consequences: builtin file tools keep their
  `file_refs`/file-change evidence and Read resolves to a `.read_only` replay
  through wrapped Run surfaces, and Host/MCP tools carry their declared
  executable categories through wrappers (ask in default mode, deny in plan,
  instead of a silent name-based allow). With a Session dispatcher present, a
  name the directory cannot resolve now conservatively classifies as
  `.execute` — never the legacy unknown-name read fallback — and dispatching
  it still fails as UnknownTool. The AgentCore C ABI is unaffected.
- ToolDispatcher metadata hardening: `validateMetadataCoverage()` walks the
  advertised directory and reports the first dispatchable name lacking
  metadata (asserted in Debug at the composed Run surface, so a wrapper that
  adds a name but forgets the metadata branch fails loudly); the session
  budget layer now classifies Tool-vs-MCP operations from the same metadata
  resolution dispatch uses instead of the unfiltered MCP view (a
  selected-but-expired alias no longer reserves under MCP caps while dispatch
  answers UnknownTool; `ToolEnvironment.mcp_view` is removed). The MCP-class
  boundary is now the `.external` executor kind, which also covers the Skill
  overlay tool — with the default equal caps this changes nothing, and the
  taxonomy question is tracked as ledger item E12. The Skill overlay also
  refuses to build over a base surface that already advertises a tool named
  `Skill` (`error.SkillToolNameCollision`) instead of silently shadowing it
  while sending duplicate definitions to the provider.
- CI migrated to self-hosted runners (Linux X64, macOS ARM64, Windows X64)
  with a pinned Lean toolchain build. No GitHub-hosted path remains in the
  workflows; restoring account billing would allow reintroducing hosted
  runners as a fallback matrix (tracked in ROADMAP M1). Pull-request jobs
  carry a fork-isolation guard, and Zig caches live in persistent per-runner
  storage so checkout's workspace clean no longer forces cold rebuilds.
- The CI workflow runs one consolidated `Gates (<platform>)` job per platform
  instead of three jobs queueing on each platform's single runner (the macOS
  test job previously waited ~5 minutes behind its sibling jobs), and Lean
  `.lake` build products persist per runner alongside the Zig caches so the
  kernel stops cold-building every run.
- `leanprover/lean-action` removed from all workflows: on every run it
  executed an unpinned installer streamed from elan's `master` branch on the
  persistent runners (the same class of mutable-fetch-and-execute the rustup
  bootstrap fix closed), cost ~40 s, and the per-run elan reinstall
  invalidated Lake's traces so the kernel rebuilt despite the restored
  `.lake`. elan is now a presence-checked runner prerequisite and CI drives
  `lake build` directly; this also removes two per-run action-tarball
  downloads from job setup, which the macOS runner's GitHub connectivity made
  expensive (a single action download was measured at 2m16s).
- Eight paid-runner L2 cases (seven in
  `scripts/eval/tests/test_memory_budget_runtime.py`, one v7-receipt case in
  `test_memory_agent_runtime.py`) that exercise the production macOS Seatbelt
  runner now skip explicitly off macOS (previously they errored on non-macOS
  hosts, and the child-signal case was mis-gated to POSIX). The macOS CI leg
  still executes them, and the maintainer rule-control gate fails closed on
  any skipped test.
- Documentation governance pass: superseded per-revision AgentCore design
  iterations, dated TUI progress transcripts, and unreferenced U-series drafts
  removed (recoverable from git history); doc index now covers the living
  document set; dangling references from source comments to removed docs
  repaired; `tests/README.md` rewritten to match the real build-step surface.
- `zig build test` now passes on a clean checkout without a Lean toolchain:
  eval cases that require the compiled Lean SDK skip explicitly when
  `control-plane/lean/.lake` is absent. CI builds Lean and sets
  `METACODES_TEST_REQUIRE_LEAN_SDK=1`, which turns that skip into a failure so
  an olean path drift cannot become a permanent silent skip; the guard path
  itself is imported from `project_harness_evolution.SDK_OLEAN_RELATIVE`.
- Extracted `metacodes` as a history-preserving standalone repository whose
  primary branch is `main`.
- Replaced vendored TinyKG source compilation with a manually maintained native
  binary contract: explicit absolute path, operator-observed SHA-256, exact CLI
  version, fresh-store format/schema probe, atomic staging, and deterministic
  provenance receipt.
- Removed ambient TinyKG discovery from runtime and tests. TinyKG-dependent gates
  now fail closed or skip explicitly when no attested binary is injected.
- Added public API, contribution, security, governance, support, third-party, and
  open-source readiness documentation.
- Removed generated evaluation-run artifacts from the published source tree;
  local copies remain ignored and recoverable from the pre-extraction history.

### Fixed

- Glob/Grep runtime dependencies now participate in tool availability
  validation (issue #8): catalog admission probes that the ripgrep executable
  actually resolves (`RG_BIN` → `PATH` → next to the host executable → system
  fallbacks), so Runtime creation fails with a typed
  `error.ToolDependencyUnavailable` — surfaced through the AgentCore ABI as
  `STATUS_INVALID_ARGUMENT` with a diagnostic naming the missing executable
  and the provisioning options — instead of advertising tools to the Provider
  that fail their first invocation with `RipgrepNotFound`. Hosts without `rg`
  select a tool set omitting `Glob`/`Grep` (probe available as
  `util_toolchain.ripgrepPath()`); dependency-free selections are unaffected.
  Locked by deterministic negative/positive tests at the toolchain, catalog,
  Runtime, and ABI layers.
- Plan-mode classification escape on the CLI (no-dispatcher) path: a model
  emitting a case-variant builtin name (e.g. `bash`) was classified by the
  unknown-name read fallback and allowed in plan mode, then deterministically
  repaired to `Bash` at dispatch and really executed. Permission
  classification and rule matching now normalize with the same resolver the
  dispatcher uses, so plan mode denies what will actually run; truly unknown
  names keep the read fallback and the UnknownTool guidance.
- `/retry` after an auto-compact could roll the conversation back past the
  compact boundary, leaving the active window projecting empty (the request
  contained only the compact summary — no user message — and later turns
  stayed hidden behind the stale boundary). The rollback now clamps the
  boundary to the retried user message under the snapshot lock.
- OpenAI streaming hardening (adversarial review of the Responses work): SSE
  lines longer than the 8KB transfer buffer no longer kill the stream with
  `StreamTooLong` — `OpenAIStream` now falls back to the same 16MB-capped
  overflow accumulation the Anthropic path uses, so Responses terminal events
  carrying the full accumulated payload (`response.output_text.done`,
  `response.completed`, `response.function_call_arguments.done`) parse instead
  of forcing a discarded, re-billed turn. Under `protocol=responses`,
  `--response-format` (as top-level `text.format`), `--prompt-cache-key`, and
  `--parallel-tool-calls` are serialized instead of silently no-oping.
  Streamed tool-call `arguments` fragments (chat and Responses) accumulate as
  raw escaped bytes and decode exactly once at flush, so a `\uXXXX` surrogate
  pair split across two deltas no longer becomes two U+FFFD. Responses event
  dispatch no longer trusts the first `"type"` in the raw event (a server
  serializing `item` before the top-level `type` previously dropped the
  function call), and parallel/interleaved Responses tool calls are covered by
  a cassette test.
- Transcript persistence survives `/retry`: the writer's append-only
  assumption broke on rollback (flushed count is monotonic), so a retry that
  shrank and regrew the conversation left the regenerated turn unpersisted
  and resuming the session revived the discarded pre-retry turn. Prefix-
  destroying mutations (retry rollback, compact's wholesale replacement) now
  bump a shrink epoch and the writer atomically rewrites the transcript.
  Semantics note: the transcript is a live-state mirror — after a rewrite,
  tool results that microcompact/truncation had already stubbed in memory
  are stubbed on disk too (resume reproduces what the model actually saw;
  previously microcompacted outputs came back verbatim on resume, and
  combined with a retry rollback the restored history could misalign). A
  no-op retry (nothing rolled back, no boundary clamp) does not trigger a
  rewrite.
- Ctrl+B (background the current session) now rotates the foreground to a
  fresh session id, transcript writer, and cleared goal state. Previously
  the fresh conversation kept the old session's writer and corrupted the
  old transcript (misaligned appends; after the rewrite fix, a prior
  retry/compact in the old session would have made the next flush replace
  it wholesale). The old session's transcript is now sealed as-is and
  stays resumable.
- Task-obligation tracking survives case-variant tool names end to end:
  both the dispatch-side accounting and the result-side met-confirmation
  now key on the canonical name / pending id (a lowercase `bash` call that
  really executed previously left the obligation unmet with a bounded
  spurious nudge).
- `/resume` now clears the active skill before switching session identity:
  previously the next run in the resumed session (e.g. an immediate
  `/retry`) executed under the previous session's skill tool policy, and the
  old skill execution state leaked (unregistered under the wrong id).
- Headless (`-p`) runs now carry the real session id into the agent loop
  (previously the default `single`), so KG task claims/leases from
  concurrent headless processes sharing a store no longer collide on one
  identity.
- `--response-format json_schema` now serializes the API-required
  `format.name` (constant `"response"`) on both the Chat Completions and
  Responses wires; both previously omitted it, so json_schema requests were
  rejected server-side with "Missing required parameter".
- OpenAI-compatible streaming now decodes the JSON string escapes of SSE
  fragments: `delta.content` and `reasoning_content` (GLM/Kimi/DeepSeek/Qwen/
  Mistral) previously reached the conversation and thinking stream as raw
  escaped bytes, so `\n`/`\t`/`\uXXXX` rendered as literals. Both paths (and
  streamed tool-call `arguments`) now share one unescaping extractor in
  `util/json.zig`.

## Historical — Stage 3 parity (2026-05-29, cc-zig line)

REPL / TUI 体验追齐。

### Added
- **History JSONL**：历史改 JSONL（每行一个 JSON 字符串），多行命令可安全 round-trip；自动迁移旧版纯文本。
- **代码块语法高亮**：render.zig 对 fenced code block 做轻量 token 高亮（关键字/字符串/数字/注释），通用关键字集覆盖 zig/c/ts/js/py/rust/go。
- **TAB 补全**：行首 slash 命令补全 + 路径补全（complete.zig）；唯一直接补全，多个列出 + 补到公共前缀。
- **Ctrl+R 反向历史搜索**：实时匹配 + Enter 接受 / Esc 取消。
- **粘贴检测 + 外部存储**：bracketed paste mode；大粘贴（>12 行或 >1600 字节）存 `~/.cc-zig/pastes/<N>.txt` + 插入 `[Pasted text #N +M lines]` 占位符，提交前展开为真实内容（paste.zig）。
- **`/agents` / `/permissions` / `/memory`**：列 sub-agent 能力 / 显示权限模式+规则 / 跨 session 记忆（`~/.cc-zig/memory.md`，`/memory add`）。

## Historical — Stage 2 parity (2026-05-29, cc-zig line)

工具层 P1 语义对齐。

### Added
- **Read 图像**：`.png/.jpg/.jpeg/.gif/.webp` 读为 base64 + media_type，api/request.zig 序列化时发成真正的 image content block（非文本 dump）；3.75MB 上限。
- **Read 设备路径黑名单**：`/dev/zero` `/dev/random` `/dev/fd/*` 等会 hang 的路径直接拒绝。
- **Edit/Write structuredPatch + gitDiff**：返回结构化 hunk（LCS diff，core/patch.zig）+ 标准 unified diff，不再只有 `{"success":true}`。
- **Edit 安全限制**：`MAX_EDIT_FILE_SIZE` 1 GiB 拒绝 + smart-quote 归一化 fallback（文件弯引号 “ ” ‘ ’ ↔ old_string 直引号）。
- **Write 自动建父目录**（mkdir -p 语义）。
- **Skill `allowed_tools` 软约束**：激活带 allowed_tools 的 skill 时在指令顶部注入工具白名单声明（硬隔离待 forked-subagent）。
- **MCP `resources/list` + `resources/read`**：client 方法 + `<server>__list_resources` / `<server>__read_resource` 工具。

## Historical — Stage 0+1 parity (2026-05-29, cc-zig line)

macOS 移植 + Phase A/B 残留补齐（当时的 survey 文档已移出仓库，见 git 历史）。

### Fixed
- **macOS 编译**：`job_registry.zig` 的 `std.c.getrandom`（macOS libc 无此调用）改为读 `/dev/urandom`。
- **macOS 崩溃**：`read_state.zig` 的 `statFd`/`statPath` 之前硬用 Linux `statx`，在 macOS 上对任何已存在文件做 Write/Edit 会 `signal SYS`。改为按 OS comptime 分支（Linux statx / 其它 fstat）。
- 测试中的 `/etc/hostname`（macOS 不存在）改为 `/etc/hosts`。
- **452→459 测试在 macOS 全绿。**

### Added
- **Headless 模式**：`-p "prompt"` / `--print` 单次运行后退出；`-` 从 stdin 读 prompt。
- **`--json`**：headless 下输出 NDJSON result 事件（stop_reason/turns/tool_calls/usage/text）。
- **`/model [name]`**：无参列当前 + 服务端 catalog；有参切换并重建 system prompt + 重算 max_tokens。
- **Grep 全局分页**：`offset` + 全局 `head_limit`（替代之前每文件 `-m`）+ `appliedLimit` 翻页提示。

## Historical — cc-zig v1.0.0 (2026-04-20, legacy internal numbering)

cc-zig 线的首个内部可用版本；该版本号属于历史 cc-zig 项目，与本仓库的
`0.1.0` semver 无关。从 TypeScript 版 Claude Code 移植到当时的 Zig dev 工具链
（现行工具链契约见 `build.zig.zon`）。

### Highlights

- **真流式 SSE**：基于 `std.Io.Reader.takeDelimiter`，首字节延迟与网络实时性一致；不再有 4MB 一次性加载
- **AbortSignal**：Ctrl+C 在 ≤ 250ms 内切断 HTTP stream 和正在运行的子进程（SIGTERM → 2s → SIGKILL，setpgid 防孤儿）
- **6 个内建工具**：Read / Write / Edit / Glob / Bash / Grep，全部对齐 TS 版参数
- **MCP 客户端**：stdio transport + JSON-RPC 2.0，动态注册到 registry
- **Skills 体系**：`~/.cc-zig/skills/<name>/SKILL.md` + 项目级覆盖 + system prompt 注入 + Skill 工具按需激活
- **REPL 增强**：termios raw mode、行编辑（↑↓←→/Home/End/Ctrl+A/E/U/K）、命令历史文件持久化、多行输入（`\` 续行 / `"""` 块）、Markdown 渲染
- **配置持久化**：`~/.cc-zig/config.json`
- **Subagent**：嵌套 agent 执行接口
- **Compact**：对话历史压缩（诚实 MVP：丢最老一半，不假摘要）

### 数据

| 指标 | 值 |
|---|---|
| 测试 | **294/294 绿** |
| ReleaseSmall 二进制 | **588K** |
| 启动时间 | < 10ms |
| 代码行数 | 7434 行 |
| 源文件数 | 44 |
| main.zig | 121 行 |

### 里程碑回顾

| M | 成果 |
|---|---|
| M0 结构重组 | 2432 行单体 → 27 文件分层，消除 `__TOOL_RESULT__:` hack，修复 `unescapeString` 内存 bug |
| M1 真流式 + Abort | EventIterator、AbortSignal、SIGINT、setpgid 子进程清理 |
| M2 工具参数对齐 | ToolContext 签名改造、Read offset/limit、Grep 9 参数、Bash timeout、Edit MultipleMatches |
| M3 权限 | 骨架就绪（M0.6），完整实现延后到沙箱阶段 |
| M4 REPL 增强 | 行编辑、历史、Markdown、多行、/retry / /compact |
| M5 MCP + Skills | stdio transport + JSON-RPC 2.0 + DynRegistry；SKILL.md 加载 + 发现 + 激活 + /skills |
| M6 配置 + Subagent + Compact | config.json 持久化、spawnAgent API、Conversation.compact |
| M7 v1.0 发布 | 全测试绿、文档更新 |

### 已知限制

- 权限系统只做 bypass/plan/deny-dangerous 骨架，完整决策树延后到沙箱版本
- Compact 采用"丢最老一半"策略，不调 API 生成摘要
- 分页（less 风格）未实现
- 语法高亮、文件名 Tab 补全未实现
- Windows/macOS 未验证（开发环境 Linux only）

### 参考

当时引用的架构计划、工作记忆与 TypeScript 原版参考均属 pre-extraction
monorepo,已不在本仓库;需要时从提取前的历史仓库查阅。
