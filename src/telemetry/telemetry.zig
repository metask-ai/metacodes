//! OpenTelemetry tracing for Metacodes Runs.
//!
//! - `span.zig`      the span model.
//! - `recorder.zig`  CoreEvent stream → GenAI semantic-convention span tree.
//! - `otlp.zig`      OTLP/JSON and OTLP protobuf encodings.
//! - `config.zig`    exporter settings from the standard `OTEL_*` variables.
//! - `exporter.zig`  batching OTLP/HTTP exporter (one per process).
//! - `store.zig`     the session's `spans.jsonl`, read by the web trace view.
//!
//! Wiring: `App` acquires the process exporter at init and releases it at
//! deinit (the last release flushes and joins it). `session_service.buildRunOptions`
//! puts a `RunTelemetry` into `agent_loop.Options`; `agent_loop.run` starts a
//! `RunTracing` from it, tees the recorder next to the frontend's backend and
//! finishes it on every exit. Recording is an observer: it adds nothing to the
//! provider request and cannot fail or slow a Run (export happens on the
//! exporter's thread).
//!
//! The session store is on by default; `METACODES_SPANS=off` turns it off.
//! Export is off until the `OTEL_*` variables configure it (`config.zig`).

const std = @import("std");
const platform = @import("platform");
const sync = platform.sync;
const log = @import("../util/log.zig");

pub const span = @import("span.zig");
pub const otlp = @import("otlp.zig");
pub const config = @import("config.zig");
pub const exporter = @import("exporter.zig");
pub const recorder = @import("recorder.zig");
pub const store = @import("store.zig");

pub const Exporter = exporter.Exporter;
pub const Recorder = recorder.Recorder;
pub const RunInfo = recorder.RunInfo;
pub const Outcome = recorder.Outcome;

/// What a Run records into. Borrowed slices must outlive the Run.
pub const RunTelemetry = struct {
    /// The session directory; spans are appended to `<dir>/spans.jsonl`.
    /// Null keeps no local copy.
    session_dir: ?[]const u8 = null,
    /// The process exporter. Null exports nothing.
    exporter: ?*Exporter = null,
};

/// The per-Run wiring `agent_loop.run` keeps on its stack. Must not move once
/// started: the recorder points at `sinks_buf`.
pub const RunTracing = struct {
    session_store: ?store.SessionStore = null,
    sinks_buf: [2]recorder.Sink = undefined,
    recorder: Recorder = undefined,

    pub fn start(self: *RunTracing, gpa: std.mem.Allocator, telemetry: RunTelemetry, info: RunInfo) void {
        self.* = .{};
        var n: usize = 0;
        if (telemetry.session_dir) |dir| {
            if (store.SessionStore.init(gpa, dir)) |s| {
                self.session_store = s;
                self.sinks_buf[n] = self.session_store.?.sink();
                n += 1;
            } else |err| log.warn("otel", "session span store unavailable: {s}", .{@errorName(err)});
        }
        if (telemetry.exporter) |e| {
            self.sinks_buf[n] = .{ .ctx = @ptrCast(e), .onEnd = exporterSink };
            n += 1;
        }
        self.recorder = Recorder.init(gpa, self.sinks_buf[0..n], info, span.nowUnixNano);
    }

    pub fn deinit(self: *RunTracing) void {
        self.recorder.deinit();
        if (self.session_store) |*s| s.deinit();
    }

    fn exporterSink(ctx: *anyopaque, s: *const span.Span) void {
        const e: *Exporter = @ptrCast(@alignCast(ctx));
        e.enqueue(s);
    }
};

/// Whether the session store is on (`METACODES_SPANS` is not `off`/`0`/`false`).
pub fn sessionStoreEnabled() bool {
    const raw = std.c.getenv("METACODES_SPANS") orelse return true;
    const v = std.mem.span(raw);
    return !(std.ascii.eqlIgnoreCase(v, "off") or std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false"));
}

/// The telemetry a session's Runs record into, or null when there is nowhere
/// to record.
pub fn forSession(session_dir: ?[]const u8) ?RunTelemetry {
    const t: RunTelemetry = .{
        .session_dir = if (sessionStoreEnabled()) session_dir else null,
        .exporter = processExporter(),
    };
    if (t.session_dir == null and t.exporter == null) return null;
    return t;
}

// ── The process exporter ────────────────────────────────────────────────

var g_mutex: sync.Mutex = .{};
var g_refs: u32 = 0;
var g_exporter: ?*Exporter = null;

/// Take a reference on the process exporter, starting it from the
/// environment on the first reference. Never fails: a configuration the
/// exporter cannot honor is logged and export stays off.
pub fn acquire(service_version: []const u8) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    g_refs += 1;
    if (g_refs > 1) return;
    g_exporter = startFromEnv(service_version);
}

/// Drop a reference; the last one flushes and stops the exporter.
pub fn release() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_refs == 0) return;
    g_refs -= 1;
    if (g_refs > 0) return;
    if (g_exporter) |e| {
        g_exporter = null;
        e.shutdown();
    }
}

pub fn processExporter() ?*Exporter {
    g_mutex.lock();
    defer g_mutex.unlock();
    return g_exporter;
}

fn startFromEnv(service_version: []const u8) ?*Exporter {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    const env = platform.paths.environment(arena.allocator()) catch {
        arena.deinit();
        return null;
    };
    const decision = config.decide(arena.allocator(), config.Lookup.fromPairs(&env), service_version) catch {
        arena.deinit();
        return null;
    };
    switch (decision) {
        .off => |why| {
            arena.deinit();
            switch (why) {
                .not_configured, .exporter_none, .sdk_disabled => {},
                .unsupported_exporter => log.warn("otel", "OTEL_TRACES_EXPORTER names no exporter metacodes has (only otlp); not exporting", .{}),
                .unsupported_protocol => log.warn("otel", "OTLP protocol not supported (use http/protobuf or http/json); not exporting", .{}),
                .invalid_endpoint => log.warn("otel", "OTLP endpoint is not an http(s) URL; not exporting", .{}),
            }
            return null;
        },
        .export_to => |cfg| {
            const e = Exporter.start(gpa, arena, cfg, service_version) catch |err| {
                log.warn("otel", "OTLP exporter did not start: {s}", .{@errorName(err)});
                return null;
            };
            log.info("otel", "exporting traces to {s} ({s}, content {s})", .{
                cfg.endpoint,
                @tagName(cfg.protocol),
                if (cfg.capture_content) "included" else "omitted",
            });
            return e;
        },
    }
}

test {
    _ = span;
    _ = otlp;
    _ = config;
    _ = exporter;
    _ = recorder;
    _ = store;
}

test "otel: RunTracing writes a Run's spans to the session store" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var tracing: RunTracing = undefined;
    tracing.start(a, .{ .session_dir = dir }, .{ .session_id = "s-1", .model = "m" });
    const be = tracing.recorder.backend();
    const tid: [12]u8 = "000000000001".*;
    be.emit(be.ctx, .single, .{ .diag_turn_begin = .{ .trace_id = tid, .depth = 0, .turn = 1 } });
    be.emit(be.ctx, .single, .{ .diag_model_request = .{ .trace_id = tid, .depth = 0, .turn = 1, .attempt = 0, .elapsed_ms = 1, .outcome = "success" } });
    be.emit(be.ctx, .single, .{ .diag_turn_end = .{ .trace_id = tid, .depth = 0, .turn = 1, .tool_calls = 0 } });
    be.emit(be.ctx, .single, .{ .diag_run_end = .{ .trace_id = tid, .depth = 0, .turns = 1, .tool_calls = 0, .stop_reason_name = "end_turn" } });
    tracing.deinit();

    const body = try store.readAsRequest(a, dir, "0");
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const spans = parsed.value.object.get("resourceSpans").?.array.items[0].object.get("scopeSpans").?.array.items[0].object.get("spans").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqualStrings("invoke_agent metacodes", spans[2].object.get("name").?.string);
}

test "otel: OTEL_* environment starts the process exporter and a Run's spans reach the collector" {
    const a = std.testing.allocator;
    const paths = platform.paths;
    if (processExporter() != null or g_refs != 0) return error.SkipZigTest; // another holder configured it
    var collector: exporter.TestCollector = undefined;
    try exporter.TestCollector.start(a, &collector);
    defer collector.deinit();
    var url_buf: [64]u8 = undefined;
    const traces_url = collector.url(&url_buf);
    const base = traces_url[0 .. traces_url.len - config.TRACES_PATH.len];
    var base_z: [64:0]u8 = undefined;
    @memcpy(base_z[0..base.len], base);
    base_z[base.len] = 0;

    paths.setEnv("OTEL_EXPORTER_OTLP_ENDPOINT", &base_z);
    paths.setEnv("OTEL_EXPORTER_OTLP_PROTOCOL", "http/json");
    paths.setEnv("OTEL_EXPORTER_OTLP_HEADERS", "authorization=Bearer%20env-token");
    paths.setEnv("OTEL_SERVICE_NAME", "env-wired");
    defer {
        paths.unsetEnv("OTEL_EXPORTER_OTLP_ENDPOINT");
        paths.unsetEnv("OTEL_EXPORTER_OTLP_PROTOCOL");
        paths.unsetEnv("OTEL_EXPORTER_OTLP_HEADERS");
        paths.unsetEnv("OTEL_SERVICE_NAME");
    }

    acquire("9.9.9");
    var released = false;
    defer if (!released) release();
    const t = forSession(null) orelse return error.TestUnexpectedResult;
    try std.testing.expect(t.exporter != null);

    var tracing: RunTracing = undefined;
    tracing.start(a, t, .{ .session_id = "env-session", .model = "m", .input = "secret prompt" });
    const be = tracing.recorder.backend();
    const tid: [12]u8 = "000000000002".*;
    be.emit(be.ctx, .single, .{ .diag_run_end = .{ .trace_id = tid, .depth = 0, .turns = 0, .tool_calls = 0, .stop_reason_name = "end_turn" } });
    tracing.deinit();
    // The last release flushes before it returns.
    release();
    released = true;
    try std.testing.expect(processExporter() == null);

    try std.testing.expectEqual(@as(usize, 1), collector.count());
    const body = collector.bodies.items[0];
    try std.testing.expectEqualStrings("application/json", collector.content_types.items[0]);
    try std.testing.expectEqualStrings("Bearer env-token", collector.auth.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stringValue\":\"env-wired\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"invoke_agent metacodes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stringValue\":\"env-session\"") != null);
    // Content capture is off unless asked for.
    try std.testing.expect(std.mem.indexOf(u8, body, "secret prompt") == null);
}
