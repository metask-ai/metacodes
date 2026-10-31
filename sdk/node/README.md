# metacodes for Node.js

Embed the [metacodes](https://github.com/metask-ai/metacodes) agent runtime in a
Node.js program. A small Node-API addon (`src/addon.c`) loads the AgentCore
shared library and runs each agent Run on its own thread, so the event loop
never blocks. No npm dependencies; Node 18 or newer on macOS or Linux.

```js
const metacodes = require('metacodes');

const runtime = new metacodes.Runtime({ tools: ['Read', 'Glob', 'Grep'] });
const session = runtime.session('claude-sonnet-4-5', { provider: 'anthropic', workspace: '.' });
const result = await session.run('Summarize this repository in three lines.');
console.log(result.text, result.stopReason, result.usage);
runtime.close();
```

A Run that stops on the model resolves normally with `stopReason === 'api_error'`,
and `result.modelError` says why: `category`, `code` and `type` (the provider's,
verbatim), `message` (safe to display), `http_status`, `request_id`, `retry`
(`'retryable'`, `'not_retryable'` or `'unknown'`), `retry_after_ms` and
`attempts`. It is `null` on any other stop. The SDK attaches no meaning to
`code`; whether it means "add funds" is yours to decide.

The API key comes from `apiKey`, else the provider's usual variable
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`), else
`METACODES_API_KEY`. `baseUrl` is the full endpoint; empty means the
provider's official one.

## Tools written in JavaScript

```js
const lookupOrder = metacodes.tool({
  name: 'lookup_order',
  description: 'Look up an order by id.',
  inputSchema: { type: 'object', properties: { id: { type: 'string' } }, required: ['id'] },
  handler: async ({ id }) => ({ id, status: 'shipped' }),   // string or anything JSON-serialisable
});
const runtime = new metacodes.Runtime({ tools: ['Read'], hostTools: [lookupOrder] });
```

Handlers may be async. A thrown error or rejected promise is returned to the
model as an ordinary tool error, and the run goes on. So is a result
`JSON.stringify` cannot encode, such as a BigInt, a cycle or a function. An
`onUiRequest` answer that cannot be encoded is not answered: the run's promise
rejects with that error.

## Events and streaming

```js
const stream = session.stream('Fix the failing test');
for await (const event of stream) {
  const [[tag, payload]] = Object.entries(event);   // "text_chunk", "tool_start", "usage", ...
  if (tag === 'text_chunk') process.stdout.write(payload);
}
const result = await stream.result;
```

`session.run(prompt, { onEvent })` delivers the same events to a callback;
every event of a Run arrives before its promise settles. `result.text` is the
final answer rebuilt from the `output_segment_*` events. The event vocabulary
is listed in [doc/AGENTCORE_BINARY_ABI.md](../../doc/AGENTCORE_BINARY_ABI.md).
`session.abort()` stops the active run; `session.submit(text)` adds user input
to it. `session.updateCredential(apiKey)` replaces the provider key in place,
also during a run and from inside a tool or handler: every request sent
afterwards (the run's next turn, a retry) carries it, and a request already
sent keeps the old one. Separate sessions run concurrently; one session runs one prompt at a
time. `session.close()` throws while a run is active, and the session stays
open; await the run, or `abort()` it, first.

## Permissions

Sessions start in `permissionMode: 'default'` with the shell disabled. A tool
call that needs approval reaches `onUiRequest`, which may be async; return an
answer or `null` (no answer means the call is not allowed):

```js
const session = runtime.session('…', {
  onUiRequest: async (request) =>
    request.kind === 'permission' && request.data.tool.name === 'Write' ? request.allowOnce() : null,
  allow: ['Read'],
  deny: ['Bash(rm *)'],
});
```

## Where the native pieces come from

`prebuilds/<platform>-<arch>/` holds the addon and, in a packaged build, the
AgentCore library and ripgrep. The library is otherwise looked up through the
`library` option, `METACODES_AGENTCORE_LIB`, `METACODES_AGENTCORE_SDK/lib`,
and the SDK of a metacodes install under `~/.local/opt/metacodes`.

## Building and testing

```sh
zig build agentcore:bundle -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
node sdk/node/scripts/build.js --bundle zig-out/agentcore/<resolved target>
node --test sdk/node/test/metacodes.test.js
```

`scripts/build.js` compiles the addon with `zig cc` against the running Node's
own headers (`NODE_INCLUDE_DIR` overrides) and copies the bundle's library and
ripgrep beside it. The tests drive the real library against a scripted local
mock provider; no network, no API key.

## Status

Experimental, like the AgentCore ABI it wraps. Not yet published to npm.
Windows is not supported yet (the addon uses `dlopen` and pthreads). Skills,
MCP, checkpoints, goals and teams exist in the ABI but are not wrapped yet;
contributions welcome.
