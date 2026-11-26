# Sealed gateway at scale

Status: design adopted 2026-10-16; §3 phase 1, §4, §5, §6 and the client side
of §6 are implemented in this tree, the rest is listed as open with its
trigger. Companion to [SEALED_SKILL_PROTOCOL.md](SEALED_SKILL_PROTOCOL.md)
(the wire contract) and [PERF_MEMORY_PRINCIPLES.md](PERF_MEMORY_PRINCIPLES.md)
(the resource red lines the gateway inherits).

## 1. The claim, as numbers

metacodes is a small static binary with no runtime and no garbage collector;
the sealed gateway turns that into a serving advantage only if it is measured.
These are the targets the load benchmark (§10) checks; a number without a
receipt is not a claim.

| Metric | Target | What a session-per-tenant agent server typically does |
|---|---|---|
| Resident memory per in-flight Step | < 1 MB, typically ~100 KB | a conversation object per session, 50–200 MB per worker process |
| In-flight Steps on 2 vCPU / 2 GB | 10 000 | hundreds |
| Gateway overhead at p99, upstream model time excluded | < 5 ms | tens to hundreds of ms |
| Cold start to first served request | < 50 ms | seconds |
| Effect of tenant count on memory | none: no per-tenant resident state | linear |

## 2. The architectural core: the Step is the unit of work

Everything below follows from one property the protocol already has: a
request is one Step. The gateway decrypts `run_state`, rebuilds the
conversation, makes one model call, renders the Step, seals the new state
and frees everything. The run's memory lifetime is the request, not the
tenant, not the session.

- All per-request allocation goes through a request arena and is released
  as a block. No cross-request references, no fragmentation, nothing to
  collect.
- Tenants share no mutable state. Skill packages are read-only; the model is
  called with the client's own route and credential (§8.1 of the protocol),
  built or lent per request. Ten tenants and ten thousand tenants are the
  same thing to the gateway.
- The price is decrypting and parsing state every Step: microseconds of CPU
  against zero residency. What must hold is the state bound
  (`MAX_STATE_BYTES`; the state carries the active window plus the
  compaction summary, never the whole history).

## 3. I/O model, in two phases behind one interface

**Phase 1 (implemented): bounded worker pool.** `Server` runs one accept
thread, a bounded queue of accepted sockets, and a fixed set of worker
threads (`--workers`, default 4 × CPU count, since a Step is mostly waiting
on the upstream). A global cap bounds the Steps whose model call is in
flight (`--max-model-calls`, default = workers). The thread count depends on
the core count only; there is no thread per tenant and none per run.

**Phase 2 (open; trigger: the benchmark shows worker threads, not upstream
latency, as the ceiling): an evented backend.** Every piece of the path —
the server, the transport, the provider clients, the shadow loop — takes an
injected `std.Io`; replacing `std.Io.Threaded` with an evented
implementation is a construction-site change in `sealed serve`, not a
rewrite, and the CLI and TUI keep their own backend untouched.

## 4. Upstream connections: the real latency and resource cost

Before this design every Step built a provider and with it a new HTTP client,
so every Step paid a TLS handshake to the upstream.

Implemented: `provider_pool.zig`, a cache of built providers keyed by a
SHA-256 fingerprint of everything that shapes the route — provider kind, base
URL, protocol, auth scheme, model, token limit, and the credential — lent to
one request at a time (a second concurrent request with the same key builds
a second entry), expired after an idle window (`--provider-cache-ms`, default
60 s) and capped in size.

What the cache buys today is the provider object: its I/O runtime, its
client and its abort registry are built once per route instead of once per
Step. It does **not** yet reuse the upstream TCP/TLS connection, because
every provider client in this tree opens a fresh connection per request
(`keep_alive = false`, a deliberate trade of handshake cost for immunity to
stale pooled connections; see the header of `packages/ai/src/api/openai_client.zig`).
That holds only with `packages/ai/src/api/http_connection.zig`: std applies
`keep_alive = false` once a response head arrives, so until 2026-10-29 a
connection whose send failed went back to the pool and every later request
in the process failed on it. Every send now goes through that file, which
closes such a connection — also what makes the stale-connection retry below
reach a fresh one. The cache is the precondition for changing that: once the gateway's clients
may keep connections alive — with a retry on the first write to a stale
one — the handshake disappears per Step with no further structural change.
That is the next item in §11.

What this costs in the protocol's terms: the client's credential lives in
process memory inside the cached client for at most one idle window after
its last use, instead of exactly one request. It is never written, never
logged, and `--provider-cache-ms 0` restores the per-request behaviour.
§8.1 and §9.2 of the protocol say so.

Open, in order: keep-alive for the gateway's provider clients (retry once
on a stale connection, the policy the CLI clients chose not to need);
then HTTP/2 to upstreams that support it (one connection, many Steps) —
trigger: upstream socket count becomes the limit before memory does.

## 5. Streaming the Step: constant memory, a live connection

Implemented: a Step is answered as an SSE stream. The headers go out at once,
a keepalive comment (`: ping`) follows every `--keepalive-ms` (default 15 s)
while the shadow loop works, and the JSON-RPC response is the final event.
The client already reads SSE (protocol §2) and skips comments, so nothing
changed on its side; proxies and the client's two-minute liveness monitor
never see a silent connection during a long model call.

Open: forwarding the model's text deltas as events (progress for the TUI).
The protocol reserves the event type; the client ignores unknown events.

## 6. Admission and back-pressure: refuse early, per tenant

Implemented, judged in this order and before any state is decrypted:

1. **Queue full** → HTTP 503 with `Retry-After` and a JSON-RPC
   `rate_limited` body, written before a byte of the request is read.
2. **Every model slot busy** (a `runs.start` / `runs.continue`, recognised by
   the method string alone) → JSON-RPC `rate_limited` with
   `data.retry_after_ms`.
3. Request size caps (unchanged).

Both rejections mean "not processed; resend unchanged" (protocol §8.4): a
refused request never reached the run, so the `seq` rule does not apply. The
client's provider waits the named interval (bounded, abortable) and resends,
up to a fixed number of attempts, then fails the run. Upstream 429/529 map to
`upstream_unavailable` and are not retried by the gateway: the client decides.

Open: per-tenant token buckets (concurrency and Steps per minute) keyed by
the bearer token — trigger: the first multi-tenant deployment; shedding
`runs.start` before `runs.continue` under overload, since a continue has
already spent money.

## 7. Memory discipline

- A request arena with a hard cap; exceeding it fails that request alone.
- Caps on `run_state`, a single tool result, the tool definitions, and Skill
  package assets, all protocol or manifest constants.
- Streaming paths never buffer a whole body; the SSE and JSON-RPC readers are
  incremental.
- The present implementation parses, re-serializes and re-parses the Step
  while building it. That is a measured-later optimisation: the benchmark
  decides whether it is visible.

## 8. Horizontal scale and keys

Stateless means any instance can answer any Step; put instances behind a
reverse proxy without session affinity. The AEAD key for `run_state` must be
shared by every instance (KMS or configuration); the key id in the blob
header (protocol §4.4) allows rotation — encrypt with the new key, still
decrypt with the old, retire on expiry. Single-host fan-out is
`SO_REUSEPORT` across processes; the binary is small and starts in
milliseconds, so a process is cheap to replace.

## 9. Server-side tools under load

`tools.server` (the manifest class, MCP-backed) shares one MCP server per
package across tenants, with connection pooling and timeouts as for the
upstream model; stateful tools such as TinyKG receive a tenant scope the
gateway injects from the token, never one the Skill picks; server-tool
execution has its own concurrency cap so a slow tool cannot starve the model
channel.

## 10. Benchmark and acceptance

What the first runs found (numbers in [BENCHMARKS.md](BENCHMARKS.md) §1):

- Every connection allocated and zeroed a cap-sized 16 MiB request buffer:
  4 ms per Step at concurrency 1 and the dominant cost. The buffer now
  starts at 64 KiB and grows to the declared length.
- `packages/ai/src/api/connection_gate.zig` bounds request setup process-wide at 8, and
  its lease covers the wait for the response head — a model's time to first
  token. Throughput sat at 8 ÷ latency whatever the worker count (249
  Steps/s at 64 clients and 20 ms). The server raises the gate to its
  model-slot cap at start; the CLI keeps the default.
- With both fixed: 1 835 Steps/s at 64 clients (p50 33 ms against a 30 ms
  mock), 7 111 Steps/s with a zero-latency mock, 1–3 ms of gateway cost per
  Step. At 256 clients the 112-thread worker pool is the limit (72 ms queue
  wait), which is the trigger for phase 2 of §3.

`zig build sealed:bench` (`scripts/sealed_gateway_bench.zig`) drives N
concurrent runs of M Steps each against a gateway whose upstream is an
in-process mock model with a configurable latency, and prints: Steps per
second, gateway overhead per Step (client-observed latency minus the mock's
latency) at p50/p95/p99, admission rejections, and provider-cache hit ratio.
Peak RSS is read with `scripts/perf_baseline.sh`'s method on the same run.
The numbers are recorded in [BENCHMARKS.md](BENCHMARKS.md) §1 with the
machine and the commit, and a regression beyond the recorded p99 is a gate
failure.

## 11. Order of work

1. Worker pool, model-slot cap, early rejection — done.
2. Provider route cache — done; upstream keep-alive on top of it — next.
3. SSE answers with keepalive; client admission retry — done.
4. Load benchmark with the first recorded numbers — done (§10, BENCHMARKS.md).
5. Evented backend, HTTP/2, multi-process — by the benchmark's verdict.
