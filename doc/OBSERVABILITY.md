# Observability: OpenTelemetry traces and the web trace view

Every Run (one `agent_loop.run`: a user message and everything the agent does
to answer it) is recorded as an OpenTelemetry span tree. The same spans go to
three places:

- **The session's span store**, `<session dir>/spans.jsonl`: on by default,
  next to the transcript.
- **The web trace view**: `GET /trace` on `--web` and `serve` shows the whole
  conversation as a waterfall, from `GET /spans`.
- **An OTLP/HTTP collector** (Jaeger, Tempo, Phoenix, Langfuse, an
  OpenTelemetry Collector...): when the standard `OTEL_*` variables configure
  one.

Recording only observes. It adds nothing to a provider request (the prompt
cache contract in [AGENTS.md](../AGENTS.md) is untouched) and cannot fail a
Run. Export runs on its own thread with bounded queues and deadlines.

Source: `src/telemetry/` (`telemetry.zig` is the map).

## Exporting to a collector

Metacodes reads no tracing settings of its own: it uses the variables the
OpenTelemetry specification defines for every SDK.

```sh
# Jaeger all-in-one: UI on :16686, OTLP/HTTP on :4318.
docker run --rm -p 16686:16686 -p 4318:4318 jaegertracing/jaeger:2.11.0

OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
OTEL_SERVICE_NAME=metacodes \
metacodes
```

| Variable | Effect |
|---|---|
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | The traces URL, used as is. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Base URL; `/v1/traces` is appended. |
| `OTEL_TRACES_EXPORTER` | `otlp` exports (to `http://localhost:4318` when no endpoint is set), `none` does not. Unset: export when an endpoint is set. Other exporters are refused with a warning. |
| `OTEL_SDK_DISABLED=true` | No export. |
| `OTEL_EXPORTER_OTLP[_TRACES]_PROTOCOL` | `http/protobuf` (default) or `http/json`. `grpc` is refused with a warning: point the endpoint at the collector's HTTP port (4318). |
| `OTEL_EXPORTER_OTLP[_TRACES]_HEADERS` | `key=value,key2=value2`, values percent-decoded (`authorization=Bearer%20<token>`). |
| `OTEL_EXPORTER_OTLP[_TRACES]_TIMEOUT` | Per-request deadline in ms (default 10000). |
| `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` | Resource attributes; `service.name` defaults to `metacodes`. |
| `OTEL_BSP_SCHEDULE_DELAY`, `OTEL_BSP_MAX_QUEUE_SIZE`, `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` | Batch processor: 5000 ms, 2048 spans, 512 spans. |
| `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true` | Export message content (see [Content](#content)). Off by default. |

The signal-specific variable wins over the general one. `METACODES_LOG=otel:info`
logs where traces go; `otel:debug` logs every export.

The exporter is one per process. It starts when the first session (App) is
created and is flushed and stopped when the last one ends, so a headless
`metacodes -p` and a daemon stopped with SIGINT exit with their spans sent. A
span is dropped, never waited for, when the queue is full; a collector that
answers an error or does not answer within the deadline costs one batch, which
is logged and dropped; nothing is retried.

## The span tree

The names and attributes follow the OpenTelemetry
[GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/);
`metacodes.*` attributes carry what the conventions do not name.

```text
invoke_agent metacodes                 one per Run (root, INTERNAL)
├── turn 1                             one per provider round (INTERNAL)
│   ├── chat <model>                   one per provider request attempt (CLIENT)
│   ├── execute_tool Bash              one per tool call (INTERNAL)
│   └── execute_tool Read
├── turn 2
│   ├── compact                        auto-compaction (INTERNAL)
│   │   └── chat <model>               the summary request
│   └── chat <model>
```

| Span | Attributes |
|---|---|
| `invoke_agent metacodes` | `gen_ai.operation.name=invoke_agent`, `gen_ai.agent.name`, `gen_ai.conversation.id` and `session.id` (the session id), `gen_ai.request.model`, `gen_ai.provider.name`, `gen_ai.usage.*` (Run totals), `metacodes.run.stop_reason`, `metacodes.run.turns`, `metacodes.run.tool_calls`, `metacodes.run.trace_id` (the id in the debug log); content: `gen_ai.input.messages`. |
| `turn N` | `metacodes.turn`, `metacodes.turn.tool_calls_total`, `metacodes.turn.tool_stage_ms`. |
| `chat <model>` | `gen_ai.operation.name=chat`, `gen_ai.request.model`, `gen_ai.provider.name`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.usage.cache_read.input_tokens`, `gen_ai.usage.cache_creation.input_tokens`, `metacodes.request.outcome`, `metacodes.request.recovery_attempt`; for a compaction summary `metacodes.request.purpose=compact`; content: `gen_ai.output.messages` (reasoning, text and `tool_call` parts). |
| `execute_tool <name>` | `gen_ai.operation.name=execute_tool`, `gen_ai.tool.name`, `gen_ai.tool.call.id`, `gen_ai.tool.type`, `metacodes.tool.elapsed_ms`, `metacodes.permission.decision`, `.source`, `.allowed`; content: `gen_ai.tool.call.arguments`, `gen_ai.tool.call.result`. |
| `compact` | `metacodes.compact.cause`, `metacodes.compact.outcome`. |

Point events become span events on the innermost open span: `cache_break`,
`breaker_tripped`, `continuation`, `auto_compact`, `context_projection`, and
`permission` for a decision whose tool never started.

Status is ERROR for a failed request (`error.type` is its outcome), a tool
that returned an error, and a Run that stopped with `api_error`, `tool_error`,
`tool_loop`, `max_tokens_exhausted` or `stalled`. A Run that ends mid-turn
(abort, error) closes its open turn and tool spans as ERROR with the reason.

Timing: a span opened by an event (turn, tool, compaction) starts when that
event happens; a model request span ends when its stream ends and starts
`elapsed_ms` earlier. Clocks are wall-clock nanoseconds.

The trace id is a fresh W3C trace id per Run; a conversation is the set of
traces with the same `gen_ai.conversation.id`.

## Content

Prompts, model output (including reasoning) and tool arguments and results
are **message content**. Following the GenAI conventions, they are exported
only with `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true`, and then
cut to 16 KiB per attribute (on a UTF-8 boundary, marked `…[truncated]`).

The session span store always keeps content, cut to 64 KiB per attribute: it
lives beside the transcript, which holds the same content at the same trust
level, and it is what the web trace view shows. `METACODES_SPANS=off` turns
the store off (export is unaffected).

## The web trace view

`metacodes --web` and `metacodes serve` serve the trace view of the session at
`GET /trace` (under `/s/<id>/` in the multi-session daemon); the chat page links
to it (`trace ↗`). It shows:

- the session's totals: runs, spans, wall time, tokens in, out and cached,
  tool calls, errors;
- every Run of the conversation on one time axis, then each Run as a waterfall:
  the span tree with each span's bar, duration, token counts and tool
  argument;
- for a selected span, its input and output messages, tool arguments and
  result, attributes and events.

It polls `GET /spans` every 2 s, so a running Run fills in as its spans end.
A resumed session shows its earlier Runs too: the store belongs to the session
directory. `OTLP JSON` downloads the request the view is showing; any OTLP/HTTP
JSON receiver accepts it as is.

`GET /spans` answers one OTLP/JSON `ExportTraceServiceRequest` holding the
store's spans in the order they ended (the newest 32 MiB of a larger store).
Both routes go through the server's normal admission: with a token, open the
page as `trace?token=<token>`.

## Not yet traced

- **Subagents and teammates** run their own `agent_loop` with their own
  backend: their Runs are not recorded yet, so a `Task` call is one
  `execute_tool Task` span. Linking a child Run under its parent's tool span
  needs the parent's span context passed to the child.
- **AgentCore** hosts (`session_host`, the C ABI) do not set
  `Options.telemetry`; an embedding host records nothing unless it does.
- **Metrics and logs** signals are not exported; token usage is on the spans.
- **gRPC** export is not supported; every collector listed above takes
  OTLP/HTTP.
