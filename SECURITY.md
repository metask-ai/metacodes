# Security policy

Metacodes is pre-1.0 and has no currently supported public release line. Security
fixes target the latest `main` commit and explicitly pinned AgentCore bundles.

Do not report vulnerabilities in a public issue. Before public launch, contact the
repository owner through a private GitHub security advisory. The public launch
checklist requires enabling private vulnerability reporting and publishing a
dedicated security contact.

Include the affected commit/bundle manifest, platform, reproduction steps, impact,
and whether credentials, sandbox escape, permission bypass, artifact disclosure,
prompt injection across trust boundaries, or TinyKG store integrity are involved.
Never attach real API keys or user data.

The project will acknowledge a complete report when a maintained response channel
is available. No response-time or embargo SLA is promised before the first public
release.

## Web and daemon trust model

`metacodes --web` and `metacodes serve` expose a session over HTTP: whoever can
use that surface can make the model run shell commands, read and write files in
the session's directories, and answer its permission questions. The rules
(normative text: [doc/API.md](doc/API.md#web-and-daemon-http-surface)):

- **Default: loopback, no token.** The server binds `127.0.0.1` and trusts the
  local user the way the terminal UI does. Two browser attacks are blocked:
  cross-site POSTs (the `Origin` must be the server's own) and DNS rebinding
  (without a token the `Host` header must be a loopback name). Other local
  users on a shared machine can still reach a loopback port; set a token there.
- **Token.** `METACODES_WEB_TOKEN` (or `--web-token`, which other local users
  can read in `ps`) makes every route except `GET /health` require
  `Authorization: Bearer <token>`, or `?token=` on a GET. The token is compared
  in constant time, checked before any request body is read, and never printed
  or logged. It travels in clear text: across a network, put the server behind
  TLS (a reverse proxy or a gateway). A browser opened with `/?token=<token>`
  removes it from the address bar; it remains in that request's line, so keep
  proxy access logs private. `METACODES_WEB_TOKEN` stays in the process
  environment, so every command the session runs (Bash, hooks, MCP servers,
  process teammates) inherits it, exactly as it inherits provider keys:
  metacodes never edits its libc environment after startup, because that
  environment block is borrowed and an `unsetenv` could leave a dangling read
  (see `src/core/auth.zig`).
- **Bind.** `--web-bind` / `METACODES_WEB_BIND` may name any IP literal. A
  non-loopback address is refused at startup unless a token is set or
  `--web-allow-unauth` is given; the latter hands the session to anyone who
  can reach the port and is meant only for networks that are already isolated.
- **`GET /health`** is unauthenticated by design: it reports only liveness,
  the version and the session count.
- **Session lifecycle** (`serve --sessions`, #254). The `/sessions` routes
  pass the same token, `Host` and `Origin` checks as every other route, so
  whoever may use one session may also create, restore and destroy sessions;
  it grants nothing a session did not already (a session can read the state
  root's transcripts through its tools). A caller-supplied id must be 24
  lowercase hex characters, so it cannot reach outside the state root's
  session directories. `--max-sessions` (default 32) bounds how many Apps,
  with their MCP and language-server children, one client can make the
  daemon hold. A fresh create never overwrites a persisted conversation, and
  a refused create builds and writes nothing.
- **UDS.** The `serve --uds <path>` transport takes no token; its only access
  control is the socket file's mode 0600. Whoever can connect can list the
  sessions, send them messages, interrupt a run, read a session's event
  stream, answer its UI requests (permission questions included) and replace
  its capability declaration. Put the socket in a private (0700)
  directory: the mode is tightened right after `bind`, and some BSD-derived
  systems ignore socket file modes.
