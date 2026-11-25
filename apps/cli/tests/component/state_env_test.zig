//! L2 for #486: `<state root>/.env`, through the real CLI.
//!
//! The CLI (`METACODES_TEST_CLI_BIN`) runs `-p` with a state root and a
//! working directory of its own, in an environment holding only what each
//! case sets (the capture starts a POSIX child with an empty one), against
//! MockServers on the loopback. An endpoint only ever comes from the process
//! environment or `config.json`, never from the file: the file cannot set
//! one, and that is one of the things checked. A case that should not reach
//! DeepSeek still points `METACODES_BASE_URL` at a MockServer, so a
//! regression lands there instead of on the real vendor.
//!
//! - the file's key and `METACODES_PROVIDER` reach the request;
//! - a file holding one provider's key selects that provider;
//! - keys of two providers and no name: the run stops, names both, and sends
//!   nothing;
//! - a `.env` in the working directory is never read;
//! - request addresses in the file are ignored, with a warning naming them
//!   and never their values, and no request goes to them;
//! - the process environment wins over the file, a provider's alias in the
//!   environment hides that provider's aliases in the file (no conflict);
//! - a Metask sign-in (`auth.json`) and a stored `/model` default both rank
//!   above the provider the file configures;
//! - the file's `METASK_API_KEY` is a sign-in only while the file names no
//!   provider other than Metask: a named DeepSeek beside it wins, and the
//!   key does not outrank a login stored in `auth.json` either;
//! - `doctor` lists the names, never the values;
//! - a subscription plan the file configures (the GLM Coding Plan) says once
//!   on stderr that `-p` is not the interactive use it is licensed for; a
//!   pay-as-you-go provider says nothing; every request names metacodes as
//!   its User-Agent, not std's `zig/<version> (std.http)`.
//!
//! In process, on a real `App` built with the layer the CLI builds
//! (`Config.credential_env_fallback`): a `/model` pick mid-session and a
//! catalog refresh read their keys from the file, behind the environment;
//! a pick of a provider that has no key and no way to sign in names the
//! variable and the file to put it in (#483).

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");

const testing = std.testing;

const OPENAI_SSE =
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n" ++
    "data: [DONE]\n\n";
const ANTHROPIC_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";
const RESPONSES_SSE =
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"ok\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":1}}}\n\n";

/// A custom provider on the OpenAI wire whose endpoint `config.json` names.
fn relayConfig(arena: std.mem.Allocator, origin: []const u8, extra: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\{{"custom_providers": {{"house-relay": {{
        \\  "display_name": "House relay",
        \\  "credential_kinds": ["api_key"],
        \\  "env_aliases": [{{"name": "HOUSE_RELAY_TOKEN", "kind": "api_key", "canonical": true}}],
        \\  "channels": [{{"id": "primary", "base_url": "{s}/relay/v1", "protocol": "openai_chat"}}],
        \\  "models": [{{"request_model_id": "relay-model", "display_name": "Relay model"}},
        \\             {{"request_model_id": "relay-model-b", "display_name": "Relay model B"}}]}}}}{s}}}
    , .{ origin, extra });
}

const Run = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
};

/// One scratch install: a state root, a working directory and a home, all
/// empty, and the CLI to run there.
const Case = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    cli: []const u8,
    root: []const u8,
    state: []const u8,
    work: []const u8,
    home: []const u8,

    fn init(self: *Case) !void {
        const raw_cli = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
        try self.initInProcess();
        errdefer self.deinit();
        self.cli = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, std.mem.span(raw_cli), self.arena());
    }

    /// The scratch directories alone, for a case that runs no CLI.
    fn initInProcess(self: *Case) !void {
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena_state.deinit();
        const a = self.arena_state.allocator();
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        self.root = try a.dupe(u8, root_buf[0..try self.tmp.dir.realPath(testing.io, &root_buf)]);
        self.cli = "";
        for ([_][]const u8{ "state", "work", "home" }) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        self.state = try std.fs.path.join(a, &.{ self.root, "state" });
        self.work = try std.fs.path.join(a, &.{ self.root, "work" });
        self.home = try std.fs.path.join(a, &.{ self.root, "home" });
    }

    fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    fn arena(self: *Case) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    /// Writes `<root>/<sub_path>`.
    fn write(self: *Case, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    /// `metacodes --state-dir <state> args…` in `work`, with only `env` (and
    /// a home, a PATH, no TinyKG start, no advisor, no model probe) set.
    fn run(self: *Case, env: []const []const u8, args: []const []const u8) !Run {
        const a = self.arena();
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        const base = [_][]const u8{
            "/usr/bin/env",
            try std.fmt.allocPrint(a, "HOME={s}", .{self.home}),
            "PATH=/usr/bin:/bin",
            "METACODES_KG_AUTOSTART=0",
            "METACODES_JEV_URL=off",
            "METACODES_NO_PROBE=1",
        };
        for (base) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        for (env) |assignment| try argv.append(a, (try a.dupeZ(u8, assignment)).ptr);
        for ([_][]const u8{ self.cli, "--state-dir", self.state }) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        try argv.append(a, null);
        const out = try cc.tools_common.spawnCaptureWithStderrTimed(
            argv.items,
            a,
            null,
            60_000,
            null,
            cc.tools_common.MAX_SPAWN_CAPTURE_BYTES,
            self.work,
        );
        return .{ .exit_code = out.exit_code, .stdout = out.stdout, .stderr = out.stderr };
    }
};

/// `http://127.0.0.1:<port>`.
fn originOf(a: std.mem.Allocator, server: *harness.MockServer) ![]const u8 {
    const url = try server.urlOwned(a);
    return url[0 .. url.len - "/v1/messages".len];
}

fn requestLine(captured: harness.CapturedRequest) []const u8 {
    const end = std.mem.indexOf(u8, captured.raw, "\r\n") orelse captured.raw.len;
    return captured.raw[0..end];
}

fn headerValue(captured: harness.CapturedRequest, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, captured.raw, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

/// The run succeeded and `server` saw exactly one request, `POST <path>`
/// with `Authorization: Bearer <key>`; returns that request.
fn expectOneRequest(run: Run, server: *harness.MockServer, path: []const u8, key: []const u8) !harness.CapturedRequest {
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ run.exit_code, run.stderr });
    try testing.expectEqual(@as(i32, 0), run.exit_code);
    try testing.expectEqual(@as(usize, 1), server.requestCount());
    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    var line_buf: [256]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&line_buf, "POST {s} HTTP/1.1", .{path}), requestLine(captured));
    var auth_buf: [256]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key}), headerValue(captured, "authorization") orelse "");
    return captured;
}

/// The request says it is metacodes (`metacodes/<semver>`), not std's default.
fn expectMetacodesUserAgent(captured: harness.CapturedRequest) !void {
    const value = headerValue(captured, "user-agent") orelse {
        std.debug.print("no user-agent in:\n{s}\n", .{captured.raw});
        return error.TestUnexpectedResult;
    };
    var expected_buf: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected_buf, "metacodes/{s}", .{cc.VERSION}), value);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find `{s}` in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

fn expectAbsent(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("`{s}` must not appear in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

test "preview: CLI flags and persisted config change the actual provider tool menu" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const scenarios = [_]struct { saved: ?[]const u8 = null, flags: []const []const u8 = &.{}, execute: bool = false, guard: bool = false, exit_code: i32 = 0 }{
        .{},
        .{ .flags = &.{"--preview"}, .execute = true, .guard = true },
        .{ .flags = &.{ "--preview", "--no-preview" } },
        .{ .flags = &.{ "--no-preview", "--preview" }, .execute = true, .guard = true },
        .{ .saved = "{\"preview\":true}", .execute = true, .guard = true },
        .{ .saved = "{\"preview\":true}", .flags = &.{"--no-preview"} },
        .{ .saved = "{\"preview\":false}", .flags = &.{"--preview"}, .execute = true, .guard = true },
        .{ .saved = "{\"nested\":{\"preview\":true}}" },
        .{ .saved = "{\"preview\" : true}", .execute = true, .guard = true },
        .{ .saved = "{\"preview\":\"true\"}" },
        .{ .saved = "{\"preview\":true,\"preview\":false}" },
        .{ .flags = &.{"--preview=execute_code"}, .execute = true },
        .{ .flags = &.{"--preview=comment_guard"}, .guard = true },
        .{ .flags = &.{ "--preview", "--no-preview=comment_guard" }, .execute = true },
        .{ .saved = "{\"preview\":{\"execute_code\":true}}", .execute = true },
        .{ .saved = "{\"preview\":{\"comment_guard\":true,\"execute_code\":false}}", .flags = &.{"--preview=execute_code"}, .execute = true, .guard = true },
        .{ .saved = "{\"preview\":true}", .flags = &.{"--no-preview=execute_code"}, .guard = true },
        .{ .flags = &.{"--preview=execute_code,bogus"}, .exit_code = 2 },
    };
    for (scenarios) |scenario| {
        var case: Case = undefined;
        try case.init();
        defer case.deinit();
        const arena = case.arena();
        if (scenario.saved) |saved| try case.write("state/config.json", saved);
        var server = try harness.MockServer.start(ANTHROPIC_SSE, 0);
        defer server.stop();
        const url = try server.urlOwned(arena);
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(arena, &.{ "--provider", "anthropic", "--api-key", "test-key", "--base-url", url, "--no-lsp", "-p", "say ok" });
        try args.appendSlice(arena, scenario.flags);
        const result = try case.run(&.{}, args.items);
        errdefer std.debug.print("preview CLI exit {d}: {s}\n", .{ result.exit_code, result.stderr });
        try testing.expectEqual(scenario.exit_code, result.exit_code);
        if (scenario.exit_code != 0) {
            try testing.expectEqual(@as(usize, 0), server.requestCount());
            continue;
        }
        try testing.expectEqual(@as(usize, 1), server.requestCount());
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, server.lastRequest().?.body(), .{});
        var found = false;
        for (parsed.value.object.get("tools").?.array.items) |tool| {
            if (std.mem.eql(u8, tool.object.get("name").?.string, "ExecuteCode")) found = true;
        }
        try testing.expectEqual(scenario.execute, found);
        const request = server.lastRequest().?.body();
        try testing.expectEqual(scenario.guard, std.mem.indexOf(u8, request, "Do not add explanatory code comments.") != null);
        try testing.expectEqual(!scenario.guard, std.mem.indexOf(u8, request, "Only add comments where the logic isn't self-evident.") != null);
    }
}

test "preview: monitor_events alone switches the Monitor tool to push events" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const scenarios = [_]struct { saved: ?[]const u8 = null, flags: []const []const u8 = &.{}, events: bool }{
        .{ .events = false },
        .{ .flags = &.{"--preview=monitor_events"}, .events = true },
        .{ .flags = &.{"--preview=execute_code"}, .events = false },
        .{ .flags = &.{"--no-preview=monitor_events"}, .events = false },
        .{ .flags = &.{ "--preview", "--no-preview=monitor_events" }, .events = false },
        .{ .saved = "{\"preview\":{\"monitor_events\":true}}", .events = true },
        .{ .saved = "{\"preview\":{\"monitor_events\":true}}", .flags = &.{"--no-preview=monitor_events"}, .events = false },
    };
    for (scenarios) |scenario| {
        var case: Case = undefined;
        try case.init();
        defer case.deinit();
        const arena = case.arena();
        if (scenario.saved) |saved| try case.write("state/config.json", saved);
        var server = try harness.MockServer.start(ANTHROPIC_SSE, 0);
        defer server.stop();
        const url = try server.urlOwned(arena);
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(arena, &.{ "--provider", "anthropic", "--api-key", "test-key", "--base-url", url, "--no-lsp", "-p", "say ok" });
        try args.appendSlice(arena, scenario.flags);
        const result = try case.run(&.{}, args.items);
        errdefer std.debug.print("monitor_events CLI exit {d}: {s}\n", .{ result.exit_code, result.stderr });
        try testing.expectEqual(@as(i32, 0), result.exit_code);
        try testing.expectEqual(@as(usize, 1), server.requestCount());
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, server.lastRequest().?.body(), .{});
        var monitor: ?std.json.Value = null;
        for (parsed.value.object.get("tools").?.array.items) |tool| {
            if (std.mem.eql(u8, tool.object.get("name").?.string, "Monitor")) monitor = tool;
        }
        const tool = monitor orelse return error.MonitorNotAdvertised;
        const properties = tool.object.get("input_schema").?.object.get("properties").?.object;
        try testing.expectEqual(scenario.events, properties.get("timeout_ms") != null);
        const description = tool.object.get("description").?.string;
        try testing.expectEqual(scenario.events, std.mem.indexOf(u8, description, "do not poll or sleep") != null);
        try testing.expectEqual(!scenario.events, std.mem.indexOf(u8, description, "BashOutput(job_id") != null);
    }
}

test "state .env: its key and METACODES_PROVIDER reach the request; one provider's key alone selects it (#486)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var deepseek = try harness.MockServer.start(OPENAI_SSE, 0);
    defer deepseek.stop();
    const base_url = try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try originOf(a, deepseek)});

    try case.write("state/.env", "# DeepSeek, for metacodes\nDEEPSEEK_API_KEY=sk-file-named\nMETACODES_PROVIDER=deepseek\nMETACODES_MODEL=deepseek-flash\n");
    const named = try case.run(&.{base_url}, &.{ "-p", "hi" });
    const named_request = try expectOneRequest(named, deepseek, "/chat/completions", "sk-file-named");
    try testing.expectEqualStrings("\"deepseek-flash\"", named_request.jsonField("model") orelse "");

    var only = try harness.MockServer.start(OPENAI_SSE, 0);
    defer only.stop();
    try case.write("state/.env", "export DEEPSEEK_API_KEY='sk-file-only'\n");
    const selected = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try originOf(a, only)})}, &.{ "-p", "hi" });
    const request = try expectOneRequest(selected, only, "/chat/completions", "sk-file-only");
    try testing.expectEqualStrings("\"deepseek-v4-pro\"", request.jsonField("model") orelse "");
}

test "state .env: a subscription plan run from -p says so once on stderr; a metered one does not; both requests name metacodes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();

    // The GLM Coding Plan, on its default (Anthropic) wire.
    var plan_server = try harness.MockServer.start(ANTHROPIC_SSE, 0);
    defer plan_server.stop();
    try case.write("state/.env", "ZAI_API_KEY=sk-plan\nMETACODES_PROVIDER=zai-coding-plan\n");
    const plan = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}/api/anthropic", .{try originOf(a, plan_server)})}, &.{ "-p", "hi" });
    const plan_request = try expectOneRequest(plan, plan_server, "/api/anthropic/v1/messages", "sk-plan");
    try expectMetacodesUserAgent(plan_request);
    const notice = "warning: Z.AI GLM Coding Plan is a subscription plan for interactive use; its terms may not cover -p, serve or CI.";
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, plan.stderr, notice));

    // DeepSeek bills by the token: nothing to say.
    var metered_server = try harness.MockServer.start(OPENAI_SSE, 0);
    defer metered_server.stop();
    try case.write("state/.env", "DEEPSEEK_API_KEY=sk-metered\nMETACODES_PROVIDER=deepseek\n");
    const metered = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try originOf(a, metered_server)})}, &.{ "-p", "hi" });
    const metered_request = try expectOneRequest(metered, metered_server, "/chat/completions", "sk-metered");
    try expectMetacodesUserAgent(metered_request);
    try expectAbsent(metered.stderr, "subscription plan");
}

test "state .env: keys of two providers and no name stop the run before any request, naming both (#486)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var server = try harness.MockServer.start(OPENAI_SSE, 0);
    defer server.stop();

    try case.write("state/.env", "DEEPSEEK_API_KEY=sk-two-deepseek-secret\nOPENAI_API_KEY=sk-two-openai-secret\n");
    // An install wrote the template beside it.
    try case.write("state/.env.example", "# template\n");
    const run = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try originOf(a, server)})}, &.{ "-p", "hi" });
    try testing.expect(run.exit_code != 0);
    try testing.expectEqual(@as(usize, 0), server.requestCount());
    try expectContains(run.stderr, "Authentication required.");
    const env_path = try std.fs.path.join(a, &.{ case.state, ".env" });
    try expectContains(run.stderr, try std.fmt.allocPrint(a, "Or use your own provider key: put it in {s} (template: {s}.example), then start again.", .{ env_path, env_path }));
    try expectContains(run.stderr, "https://github.com/metask-ai/metacodes/blob/main/doc/LOCAL_CONFIG.md");
    try expectContains(run.stderr, try std.fmt.allocPrint(a, "{s} holds keys for several providers (deepseek, openai) and names none: add METACODES_PROVIDER=<id> to choose one.", .{env_path}));
    try expectAbsent(run.stderr, "sk-two-deepseek-secret");
    try expectAbsent(run.stderr, "sk-two-openai-secret");
}

test "state .env: a .env in the working directory is never read (#486)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var server = try harness.MockServer.start(OPENAI_SSE, 0);
    defer server.stop();

    // What a cloned repository could ship.
    try case.write("work/.env", "DEEPSEEK_API_KEY=sk-from-the-repository\nMETACODES_PROVIDER=deepseek\n");
    const run = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try originOf(a, server)})}, &.{ "-p", "hi" });
    try testing.expect(run.exit_code != 0);
    try testing.expectEqual(@as(usize, 0), server.requestCount());
    try expectContains(run.stderr, "Authentication required.");
    // The hint names the state root's file, and no template that is not there.
    try expectContains(run.stderr, try std.fmt.allocPrint(a, "put it in {s}, then start again.", .{try std.fs.path.join(a, &.{ case.state, ".env" })}));
    try expectAbsent(run.stderr, "sk-from-the-repository");
}

test "state .env: request addresses in it are ignored with a warning, and no request goes there (#486)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var relay = try harness.MockServer.start(OPENAI_SSE, 0);
    defer relay.stop();
    var decoy = try harness.MockServer.start(ANTHROPIC_SSE, 0);
    defer decoy.stop();
    const decoy_origin = try originOf(a, decoy);

    // Nothing but the file could move the relay's request: no flag and no
    // environment variable names an endpoint.
    try case.write("state/config.json", try relayConfig(a, try originOf(a, relay), ""));
    try case.write("state/.env", try std.fmt.allocPrint(a,
        \\HOUSE_RELAY_TOKEN=sk-relay
        \\METACODES_BASE_URL={s}/relay/v1
        \\METASK_GATEWAY_URL={s}
        \\METASK_SITE_URL={s}
        \\RELAY_PROXY_URL={s}
        \\
    , .{ decoy_origin, decoy_origin, decoy_origin, decoy_origin }));
    const run = try case.run(&.{}, &.{ "-p", "hi" });
    _ = try expectOneRequest(run, relay, "/relay/v1/chat/completions", "sk-relay");
    try testing.expectEqual(@as(usize, 0), decoy.requestCount());
    try expectContains(run.stderr, "warning: ");
    for ([_][]const u8{ "METACODES_BASE_URL", "METASK_GATEWAY_URL", "METASK_SITE_URL", "RELAY_PROXY_URL" }) |name| {
        try expectContains(run.stderr, name);
    }
    try expectContains(run.stderr, "custom_providers");
    // Names only: neither the addresses nor the key.
    try expectAbsent(run.stderr, decoy_origin);
    try expectAbsent(run.stderr, "sk-relay");
}

test "state .env: the process environment wins, and another alias of the provider there is no conflict (#486)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();

    // The file's provider, the environment's key and model.
    var deepseek = try harness.MockServer.start(OPENAI_SSE, 0);
    defer deepseek.stop();
    try case.write("state/.env", "DEEPSEEK_API_KEY=sk-file\nMETACODES_PROVIDER=deepseek\nMETACODES_MODEL=deepseek-flash\n");
    const overridden = try case.run(&.{
        try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try originOf(a, deepseek)}),
        "DEEPSEEK_API_KEY=sk-process",
        "METACODES_MODEL=deepseek-v4-pro",
    }, &.{ "-p", "hi" });
    const request = try expectOneRequest(overridden, deepseek, "/chat/completions", "sk-process");
    try testing.expectEqualStrings("\"deepseek-v4-pro\"", request.jsonField("model") orelse "");

    // METACODES_PROVIDER in the environment outranks the file's; the file
    // still supplies that provider's key.
    var named = try harness.MockServer.start(OPENAI_SSE, 0);
    defer named.stop();
    try case.write("state/.env", "OPENAI_API_KEY=sk-file-openai\nMETACODES_PROVIDER=openai\nDEEPSEEK_API_KEY=sk-file-deepseek\n");
    const chosen = try case.run(&.{
        try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try originOf(a, named)}),
        "METACODES_PROVIDER=deepseek",
    }, &.{ "-p", "hi" });
    _ = try expectOneRequest(chosen, named, "/chat/completions", "sk-file-deepseek");

    // Kimi Code reads KIMI_CODE_API_KEY and KIMI_API_KEY. One in the
    // environment and the other, with another value, in the file: the
    // environment's key, where the two in one place are refused as conflicting.
    var kimi = try harness.MockServer.start(RESPONSES_SSE, 0);
    defer kimi.stop();
    try case.write("state/.env", "KIMI_CODE_API_KEY=sk-file-kimi\nMETACODES_PROVIDER=kimi-code\n");
    const shadowed = try case.run(&.{
        try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}/coding/v1", .{try originOf(a, kimi)}),
        "KIMI_API_KEY=sk-process-kimi",
    }, &.{ "-p", "hi" });
    _ = try expectOneRequest(shadowed, kimi, "/coding/v1/responses", "sk-process-kimi");
    try expectAbsent(shadowed.stderr, "Conflicting credentials");
}

test "state .env: a Metask sign-in and a stored /model default rank above the provider it configures (#486)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();

    // auth.json holds a complete Metask login: the historical path runs, and
    // METACODES_BASE_URL (a MockServer) takes its request. Had the file's
    // DeepSeek won, the same base URL would have taken it at another path
    // with the file's key.
    var metask = try harness.MockServer.start(ANTHROPIC_SSE, 0);
    defer metask.stop();
    var login = cc.core_auth.StoredCredentials{
        .api_key = try testing.allocator.dupe(u8, "sk-metask-stored"),
        .selected_model = try testing.allocator.dupe(u8, "claude-sonnet-4-20250514"),
        .reasoning_effort = .high,
    };
    defer login.deinit(testing.allocator);
    try cc.core_auth.saveToPath(testing.allocator, try std.fs.path.join(a, &.{ case.state, "auth.json" }), login);
    try case.write("state/.env", "DEEPSEEK_API_KEY=sk-file\nMETACODES_PROVIDER=deepseek\n");
    const signed_in = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}/v1/messages", .{try originOf(a, metask)})}, &.{ "-p", "hi" });
    _ = try expectOneRequest(signed_in, metask, "/v1/messages", "sk-metask-stored");
    try case.tmp.dir.deleteFile(testing.io, "state/auth.json");

    // A default stored with /model names the relay. The file still supplies
    // that provider's key: only its choice of provider ranks last.
    var relay = try harness.MockServer.start(OPENAI_SSE, 0);
    defer relay.stop();
    var decoy = try harness.MockServer.start(OPENAI_SSE, 0);
    defer decoy.stop();
    try case.write("state/config.json", try relayConfig(a, try originOf(a, relay),
        \\, "global_selection": {"target": {"kind": "auto_route", "selector": "relay-model"}, "scope": "global"}
    ));
    try case.write("state/.env", "DEEPSEEK_API_KEY=sk-file\nMETACODES_PROVIDER=deepseek\nHOUSE_RELAY_TOKEN=sk-relay-from-file\n");
    const stored = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try originOf(a, decoy)})}, &.{ "-p", "hi" });
    _ = try expectOneRequest(stored, relay, "/relay/v1/chat/completions", "sk-relay-from-file");
    try testing.expectEqual(@as(usize, 0), decoy.requestCount());
}

test "state .env: the provider it names outranks the METASK_API_KEY beside it; unnamed, that key signs in (#486)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();

    // The file names DeepSeek. Its Metask key is there for when Metask is
    // chosen; it must not turn the start into a Metask sign-in.
    var deepseek = try harness.MockServer.start(OPENAI_SSE, 0);
    defer deepseek.stop();
    try case.write("state/.env", "METASK_API_KEY=sk-metask-file\nDEEPSEEK_API_KEY=sk-deepseek-file\nMETACODES_PROVIDER=deepseek\n");
    const named = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try originOf(a, deepseek)})}, &.{ "-p", "hi" });
    _ = try expectOneRequest(named, deepseek, "/chat/completions", "sk-deepseek-file");

    // Named Metask, or no name at all: the file's Metask key signs in the way
    // the environment variable does, and the historical path runs with it.
    for ([_][]const u8{
        "METASK_API_KEY=sk-metask-file\nDEEPSEEK_API_KEY=sk-deepseek-file\nMETACODES_PROVIDER=metask\n",
        "METASK_API_KEY=sk-metask-file\nDEEPSEEK_API_KEY=sk-deepseek-file\n",
    }) |text| {
        var metask = try harness.MockServer.start(ANTHROPIC_SSE, 0);
        defer metask.stop();
        try case.write("state/.env", text);
        const signed_in = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}/v1/messages", .{try originOf(a, metask)})}, &.{ "-p", "hi" });
        _ = try expectOneRequest(signed_in, metask, "/v1/messages", "sk-metask-file");
    }

    // A login stored in auth.json signs the start in, and the file names
    // DeepSeek: its Metask key counts nowhere on the historical path, so it
    // does not outrank the stored key either.
    var stored_metask = try harness.MockServer.start(ANTHROPIC_SSE, 0);
    defer stored_metask.stop();
    var login = cc.core_auth.StoredCredentials{
        .api_key = try testing.allocator.dupe(u8, "sk-metask-stored"),
        .selected_model = try testing.allocator.dupe(u8, "claude-sonnet-4-20250514"),
        .reasoning_effort = .high,
    };
    defer login.deinit(testing.allocator);
    try cc.core_auth.saveToPath(testing.allocator, try std.fs.path.join(a, &.{ case.state, "auth.json" }), login);
    try case.write("state/.env", "METASK_API_KEY=sk-metask-file\nDEEPSEEK_API_KEY=sk-deepseek-file\nMETACODES_PROVIDER=deepseek\n");
    const with_login = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}/v1/messages", .{try originOf(a, stored_metask)})}, &.{ "-p", "hi" });
    _ = try expectOneRequest(with_login, stored_metask, "/v1/messages", "sk-metask-stored");
}

test "state .env: doctor lists the names it reads and ignores, never a value (#486)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();

    try case.write("state/.env",
        \\DEEPSEEK_API_KEY=sk-doctor-secret
        \\METACODES_PROVIDER=deepseek
        \\METACODES_BASE_URL=http://127.0.0.1:9/doctor-secret-path
        \\FOO=foo-secret-value
        \\not an assignment sk-line-secret
        \\
    );
    const json = try case.run(&.{}, &.{ "doctor", "--json" });
    try testing.expectEqual(@as(i32, 0), json.exit_code);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json.stdout, .{});
    const local = parsed.object.get("local_config") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ case.state, ".env" }), local.object.get("path").?.string);
    try testing.expectEqualStrings("read", local.object.get("state").?.string);
    const accepted = local.object.get("accepted").?.array.items;
    try testing.expectEqual(@as(usize, 2), accepted.len);
    try testing.expectEqualStrings("DEEPSEEK_API_KEY", accepted[0].string);
    try testing.expectEqualStrings("METACODES_PROVIDER", accepted[1].string);
    const ignored = local.object.get("ignored").?.array.items;
    try testing.expectEqual(@as(usize, 2), ignored.len);
    try testing.expectEqualStrings("METACODES_BASE_URL", ignored[0].string);
    try testing.expectEqualStrings("FOO", ignored[1].string);
    try testing.expectEqual(@as(i64, 5), local.object.get("malformed_lines").?.array.items[0].integer);

    const plain = try case.run(&.{}, &.{ "doctor", "--plain" });
    try expectContains(plain.stdout, "local_config ");
    try expectContains(plain.stdout, " accepted=DEEPSEEK_API_KEY,METACODES_PROVIDER ignored=METACODES_BASE_URL,FOO malformed_lines=5");
    for ([_]Run{ json, plain }) |run| {
        for ([_][]const u8{ "sk-doctor-secret", "doctor-secret-path", "foo-secret-value", "sk-line-secret" }) |value| {
            try expectAbsent(run.stdout, value);
            try expectAbsent(run.stderr, value);
        }
    }
}

// ── in process: the App's own reads ─────────────────────────────────────────

const ppaths = @import("platform").paths;
const App = cc.app_module.App;

/// Sets (or unsets, with null) one variable and puts the old value back.
const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            testing.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
    }
};

/// What could supply a credential, move a route, or start background work
/// the case did not ask for; then a scratch home and no probe, no KG start.
const InProcessEnv = struct {
    guards: [9]EnvGuard = undefined,
    count: usize = 0,

    fn init(self: *InProcessEnv, home: [*:0]const u8) !void {
        self.count = 0;
        const settings = [_]struct { [*:0]const u8, ?[*:0]const u8 }{
            .{ "HOUSE_RELAY_TOKEN", null },
            .{ "CATALOG_TOKEN", null },
            .{ "METASK_API_KEY", null },
            .{ "METASK_GATEWAY_URL", null },
            .{ "METACODES_PROVIDER", null },
            .{ "METACODES_CONFIG_FILE", null },
            .{ "HOME", home },
            .{ "METACODES_NO_PROBE", "1" },
            .{ "METACODES_KG_AUTOSTART", "0" },
        };
        errdefer self.deinit();
        for (settings) |setting| {
            self.guards[self.count] = try EnvGuard.set(setting[0], setting[1]);
            self.count += 1;
        }
    }

    fn deinit(self: *InProcessEnv) void {
        while (self.count > 0) {
            self.count -= 1;
            self.guards[self.count].restore();
        }
    }
};

/// Send one turn on whatever route the session is on now.
fn sendOneTurn(app: *App) !void {
    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = try app.provider().sendStream(&messages, null, null, null, null, null, "");
    defer handle.deinit();
    while (try handle.next()) |event| switch (event) {
        .text => |text| app.allocator.free(text),
        else => {},
    };
}

/// A session started on the historical path (`--api-key`, Metask), whose
/// `/model` picks bind the relay `config.json` defines.
fn startedApp(case: *Case, io: std.Io, layer: ?*const cc.app_state_env.Loaded) !*App {
    var config = cc.parseArgsForTest(&.{ "metacodes", "--api-key", "sk-metask-flag", "--base-url", "http://127.0.0.1:9/v1/messages", "--model", "claude-sonnet-4-6" }, case.arena());
    try testing.expect(config.parse_error == null);
    config.state_root = case.state;
    config.credential_env_fallback = if (layer) |loaded| loaded.lookup() else null;
    return App.init(testing.allocator, io, config, "sk-metask-flag");
}

test "state .env: a /model pick mid-session reads the provider's key from it, behind the environment (#486)" {
    var case: Case = undefined;
    try case.initInProcess();
    defer case.deinit();
    const a = case.arena();
    var env: InProcessEnv = .{};
    try env.init((try a.dupeZ(u8, case.home)).ptr);
    defer env.deinit();
    var relay = try harness.MockServer.startCassette(&.{ OPENAI_SSE, OPENAI_SSE }, 0);
    defer relay.stop();
    try case.write("state/config.json", try relayConfig(a, try originOf(a, relay), ""));
    try case.write("state/.env", "HOUSE_RELAY_TOKEN=sk-relay-from-file\n");
    var layer = try cc.app_state_env.load(testing.allocator, case.state, .{
        .keys = &.{.{ .name = "HOUSE_RELAY_TOKEN", .provider = "house-relay" }},
    });
    defer layer.deinit();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    // Without the layer the relay has no key: the pick is refused.
    {
        const bare = try startedApp(&case, io_runtime.io(), null);
        defer bare.deinit();
        const refused = cc.repl_picker_host.useSelector(bare, "relay-model");
        try testing.expect(refused == .failed);
        try testing.expectEqualStrings("MissingCredentials", refused.failed);
    }

    const app = try startedApp(&case, io_runtime.io(), &layer);
    defer app.deinit();
    try testing.expect(cc.repl_picker_host.useSelector(app, "relay-model") == .switched);
    try sendOneTurn(app);
    const from_file = relay.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expectEqualStrings("Bearer sk-relay-from-file", headerValue(from_file, "authorization") orelse "");

    // The environment's value wins over the file's from the next binding on.
    ppaths.setEnv("HOUSE_RELAY_TOKEN", "sk-relay-from-env");
    try testing.expect(cc.repl_picker_host.useSelector(app, "relay-model-b") == .switched);
    try sendOneTurn(app);
    const from_env = relay.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expectEqualStrings("Bearer sk-relay-from-env", headerValue(from_env, "authorization") orelse "");
    try testing.expectEqualStrings("\"relay-model-b\"", from_env.jsonField("model") orelse "");
}

test "state .env: a catalog refresh reads its credential_env from it (#486)" {
    var case: Case = undefined;
    try case.initInProcess();
    defer case.deinit();
    const a = case.arena();
    var env: InProcessEnv = .{};
    try env.init((try a.dupeZ(u8, case.home)).ptr);
    defer env.deinit();
    var catalog = try harness.MockServer.startRepeatingStatus("{\"data\":[]}", "HTTP/1.1 200 OK", "");
    defer catalog.stop();
    // Not "openrouter": that id is built in, and a configured catalog naming
    // it is passed over.
    try case.write("state/config.json", try std.fmt.allocPrint(a,
        \\{{"provider_catalogs": {{"or-catalog": {{"models_url": "{s}/api/v1/models", "credential_env": "CATALOG_TOKEN"}}}}}}
    , .{try originOf(a, catalog)}));
    try case.write("state/.env", "CATALOG_TOKEN=sk-catalog-from-file\n");
    var layer = try cc.app_state_env.load(testing.allocator, case.state, .{ .others = &.{"CATALOG_TOKEN"} });
    defer layer.deinit();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    const app = try startedApp(&case, io_runtime.io(), &layer);
    defer app.deinit();
    _ = app.refreshProviderCatalogs() catch 0;
    try testing.expect(catalog.requestCount() >= 1);
    for (0..catalog.requestCount()) |index| {
        const request = catalog.requestAt(index) orelse continue;
        try testing.expect(std.mem.startsWith(u8, requestLine(request), "GET /api/v1/models "));
        try testing.expectEqualStrings("Bearer sk-catalog-from-file", headerValue(request, "authorization") orelse "");
    }
}

/// The picker as it is drawn, monochrome, 160 columns wide.
fn drawPicker(app: *App, buffer: []u8) []const u8 {
    return drawPickerAt(app, buffer, 160);
}

/// The picker as it is drawn, monochrome, `cols` columns wide.
fn drawPickerAt(app: *App, buffer: []u8, cols: usize) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    _ = cc.repl_model_picker_view.render(&app.model_picker, &writer, cc.tui_theme.monochrome, cols);
    return writer.buffered();
}

/// What a drawn picker shows, as text: every row without its escape
/// sequences and the blanks around it, and a `\n` after it.
fn screenOf(arena: std.mem.Allocator, drawn: []const u8) ![]const u8 {
    const plain = try cc.tui_test_capture.stripAnsi(arena, drawn);
    var out: std.ArrayList(u8) = .empty;
    var rows = std.mem.splitSequence(u8, plain, "\r\n");
    try out.appendSlice(arena, std.mem.trim(u8, rows.first(), " "));
    while (rows.next()) |row| {
        try out.append(arena, '\n');
        try out.appendSlice(arena, std.mem.trim(u8, row, " "));
    }
    return out.items;
}

const Span = struct { start: usize, end: usize };

/// Where `sentence` is on `screen` (`screenOf`), read on over the row ends
/// as the user reads it. The picker breaks a line at a space, and a word
/// longer than a row (a path, a link) where the row ends, so a row end
/// either stands for a space of the sentence or falls inside one of its
/// words. `null` when it is not there.
fn findAcrossRows(screen: []const u8, sentence: []const u8) ?Span {
    for (0..screen.len) |start| {
        // A sentence starts on a row, not at the end of the one before.
        if (screen[start] == '\n') continue;
        var at = start;
        const found = for (sentence) |byte| {
            if (at < screen.len and screen[at] == '\n') {
                at += 1;
                if (byte == ' ') continue;
            }
            if (at >= screen.len or screen[at] != byte) break false;
            at += 1;
        } else true;
        if (found) return .{ .start = start, .end = at };
    }
    return null;
}

/// Filter the picker to `provider`, as a user who types its name, and put
/// the cursor on its first model. `error.ProviderNotListed` when no model of
/// it is listed: a provider no credential resolves for is not (#488).
fn cursorOnProvider(app: *App, ui: *cc.tui_ui_state.UiState, provider: []const u8) !cc.repl_model_picker.Group {
    const picker = &app.model_picker;
    for (provider) |byte| _ = cc.repl_picker_host.onKey(app, ui, .{ .char = byte }, .unguarded);
    var rows = cc.repl_model_picker.Picker.RowBuffer.init(testing.allocator);
    defer rows.deinit();
    // Other providers' models can match the name too ("kimi" also finds
    // kimi-code's): down until the cursor is on this one's.
    for (0..64) |_| {
        const listed = try picker.rows(&rows);
        if (listed.len == 0) return error.ProviderNotListed;
        const row = listed[@min(picker.cursor, listed.len - 1)];
        if (row == .model and picker.offers.items[row.model.offer_index].provider_id.eqlText(provider)) return row.model;
        _ = cc.repl_picker_host.onKey(app, ui, .down, .unguarded);
    }
    return error.ProviderNotListed;
}

/// The picker is the setup of a provider that has no key (#483): it names
/// `variable` and the file to put it in, the guide and the keys that leave;
/// not the bare error name, and no way to type a key in.
fn expectSetupOf(arena: std.mem.Allocator, app: *App, variable: []const u8, env_path: []const u8) !void {
    const where_to = try std.fmt.allocPrint(arena, "Set {s} in {s}, then restart", .{ variable, env_path });
    const guide = "How to: https://github.com/metask-ai/metacodes/blob/main/doc/LOCAL_CONFIG.md";
    const keys = "esc back · q close";

    // 160 columns hold what names no path on a row of its own, in any
    // checkout. The sentence naming this install's `.env` is as long as the
    // checkout's path makes it (the scratch state root is under its
    // `.zig-cache`): one row in a short checkout, more in a longer one. So
    // that sentence is read on over the row ends.
    var wide_buffer: [16384]u8 = undefined;
    const wide = try screenOf(arena, drawPicker(app, &wide_buffer));
    try expectContains(wide, guide);
    try expectContains(wide, keys);
    try expectNoErrorNameNoKeyEntry(wide, try expectAcrossRows(wide, where_to));

    // 40 columns hold neither the path nor the link on one row, in any
    // checkout: the reading a long checkout needs at 160 is exercised in a
    // short one too.
    var narrow_buffer: [16384]u8 = undefined;
    const narrow = try screenOf(arena, drawPickerAt(app, &narrow_buffer, 40));
    _ = try expectAcrossRows(narrow, guide);
    try expectContains(narrow, keys);
    try expectNoErrorNameNoKeyEntry(narrow, try expectAcrossRows(narrow, where_to));
}

/// `sentence` is on `screen`, whichever rows it is on; returns where.
fn expectAcrossRows(screen: []const u8, sentence: []const u8) !Span {
    return findAcrossRows(screen, sentence) orelse {
        std.debug.print("missing from the picker: {s}\n{s}\n", .{ sentence, screen });
        return error.TestUnexpectedResult;
    };
}

/// Not the bare error name, and no way to type a key in, anywhere on
/// `screen` but in the sentence at `path_sentence`: that one holds the
/// checkout's path, and a checkout can be named anything.
fn expectNoErrorNameNoKeyEntry(screen: []const u8, path_sentence: Span) !void {
    for ([_][]const u8{ screen[0..path_sentence.start], screen[path_sentence.end..] }) |rest| {
        for ([_][]const u8{ "MissingCredentials", "paste" }) |gone| {
            if (findAcrossRows(rest, gone) == null) continue;
            std.debug.print("`{s}` must not be on the picker:\n{s}\n", .{ gone, screen });
            return error.TestUnexpectedResult;
        }
    }
}

test "state .env: a provider with no key is not listed, and nothing leads to its setup (#483, #488)" {
    var case: Case = undefined;
    try case.initInProcess();
    defer case.deinit();
    const a = case.arena();
    var env: InProcessEnv = .{};
    try env.init((try a.dupeZ(u8, case.home)).ptr);
    defer env.deinit();
    var moonshot = try EnvGuard.set("MOONSHOT_API_KEY", null);
    defer moonshot.restore();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();
    const app = try startedApp(&case, io_runtime.io(), null);
    defer app.deinit();

    var ui: cc.tui_ui_state.UiState = .{};
    cc.repl_picker_host.open(app, &ui, .unguarded);
    // Moonshot's open platform (`kimi`): no key, so no model of it is
    // listed, and no setup is shown.
    try testing.expectError(error.ProviderNotListed, cursorOnProvider(app, &ui, "kimi"));
    try testing.expectEqual(cc.repl_model_picker.Stage.list, app.model_picker.stage);
    try testing.expect(app.model_picker.setup == null);
    var buffer: [16384]u8 = undefined;
    const text = drawPicker(app, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, "MOONSHOT_API_KEY") == null);
    try testing.expectEqualStrings("claude-sonnet-4-6", app.activeModel());
}

test "state .env: a provider whose two key names disagree stays listed, and a pick says why, not where a key goes (#488)" {
    var case: Case = undefined;
    try case.initInProcess();
    defer case.deinit();
    const a = case.arena();
    var env: InProcessEnv = .{};
    try env.init((try a.dupeZ(u8, case.home)).ptr);
    defer env.deinit();
    // Both of Gemini's names, holding different keys: resolution refuses
    // them as ambiguous. A setup saying "set GEMINI_API_KEY" would point at
    // a variable that is already set.
    var gemini = try EnvGuard.set("GEMINI_API_KEY", "sk-placeholder-gemini-one");
    defer gemini.restore();
    var google = try EnvGuard.set("GOOGLE_API_KEY", "sk-placeholder-gemini-two");
    defer google.restore();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();
    const app = try startedApp(&case, io_runtime.io(), null);
    defer app.deinit();

    const picker = &app.model_picker;
    var ui: cc.tui_ui_state.UiState = .{};
    cc.repl_picker_host.open(app, &ui, .unguarded);
    _ = try cursorOnProvider(app, &ui, "gemini");
    // Enter on the model applies its preferred route.
    _ = cc.repl_picker_host.onKey(app, &ui, .enter, .unguarded);

    try testing.expect(picker.stage != .setup);
    var buffer: [16384]u8 = undefined;
    const text = drawPicker(app, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, "switch failed (AmbiguousCredentialAliases); the previous route is still active") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Set GEMINI_API_KEY") == null);
    try testing.expectEqualStrings("claude-sonnet-4-6", app.activeModel());
}

test "state .env: a pick whose key went away after the picker opened shows the provider's setup, not the bare error (#483)" {
    var case: Case = undefined;
    try case.initInProcess();
    defer case.deinit();
    const a = case.arena();
    var env: InProcessEnv = .{};
    try env.init((try a.dupeZ(u8, case.home)).ptr);
    defer env.deinit();
    var moonshot = try EnvGuard.set("MOONSHOT_API_KEY", "sk-moonshot-for-a-moment");
    defer moonshot.restore();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();
    const app = try startedApp(&case, io_runtime.io(), null);
    defer app.deinit();

    const picker = &app.model_picker;
    var ui: cc.tui_ui_state.UiState = .{};
    cc.repl_picker_host.open(app, &ui, .unguarded);
    _ = try cursorOnProvider(app, &ui, "kimi");
    // The key goes, then Enter on the model applies its route.
    try testing.expectEqual(cc.repl_model_picker.Stage.list, picker.stage);
    ppaths.unsetEnv("MOONSHOT_API_KEY");
    try testing.expectEqual(cc.repl_picker_host.Result.redraw, cc.repl_picker_host.onKey(app, &ui, .enter, .unguarded));

    try testing.expectEqual(cc.repl_model_picker.Stage.setup, picker.stage);
    var buffer: [16384]u8 = undefined;
    const text = drawPicker(app, &buffer);
    try testing.expect(std.mem.indexOf(u8, text, "no credential for kimi; the previous route is still active") != null);
    try expectSetupOf(a, app, "MOONSHOT_API_KEY", try std.fs.path.join(a, &.{ case.state, ".env" }));
    try testing.expectEqualStrings("claude-sonnet-4-6", app.activeModel());
    // Esc goes back to the model the user was applying, in the list.
    _ = cc.repl_picker_host.onKey(app, &ui, .escape, .unguarded);
    try testing.expectEqual(cc.repl_model_picker.Stage.list, picker.stage);
    const back = picker.focusedOffer() orelse return error.NoFocusedRoute;
    try testing.expect(back.provider_id.eqlText("kimi"));
}

test "state .env: /model lists a provider whose key is only in the file as one a pick applies, with the file's key (#488)" {
    var case: Case = undefined;
    try case.initInProcess();
    defer case.deinit();
    const a = case.arena();
    var env: InProcessEnv = .{};
    try env.init((try a.dupeZ(u8, case.home)).ptr);
    defer env.deinit();
    var moonshot = try EnvGuard.set("MOONSHOT_API_KEY", null);
    defer moonshot.restore();
    try case.write("state/.env", "MOONSHOT_API_KEY=sk-moonshot-from-file\n");
    var layer = try cc.app_state_env.load(testing.allocator, case.state, .{
        .keys = &.{.{ .name = "MOONSHOT_API_KEY", .provider = "kimi" }},
    });
    defer layer.deinit();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    // Without the layer, the same install does not list Kimi.
    {
        const bare = try startedApp(&case, io_runtime.io(), null);
        defer bare.deinit();
        var ui: cc.tui_ui_state.UiState = .{};
        cc.repl_picker_host.open(bare, &ui, .unguarded);
        try testing.expectError(error.ProviderNotListed, cursorOnProvider(bare, &ui, "kimi"));
    }

    const app = try startedApp(&case, io_runtime.io(), &layer);
    defer app.deinit();
    var ui: cc.tui_ui_state.UiState = .{};
    cc.repl_picker_host.open(app, &ui, .unguarded);
    _ = try cursorOnProvider(app, &ui, "kimi");
    var result: cc.repl_picker_host.Result = .ignored;
    for (0..4) |_| {
        result = cc.repl_picker_host.onKey(app, &ui, .enter, .unguarded);
        if (result == .committed) break;
    }
    try testing.expectEqual(cc.repl_picker_host.Result.committed, result);
    try testing.expectEqualStrings("sk-moonshot-from-file", app.api_key);
    try testing.expect(std.mem.indexOf(u8, app.model_picker.notice(), "from now on billed to your Moonshot Kimi account") != null);
}

/// A session started on the relay `config.json` defines, with its own key:
/// not on Metask, so no Metask key of the session's own.
fn relayApp(case: *Case, io: std.Io) !*App {
    var config = cc.parseArgsForTest(&.{ "metacodes", "--provider", "house-relay", "--api-key", "sk-relay-flag", "--base-url", "http://127.0.0.1:9/relay/v1", "--model", "relay-model" }, case.arena());
    try testing.expect(config.parse_error == null);
    config.state_root = case.state;
    return App.init(testing.allocator, io, config, "sk-relay-flag");
}

test "state .env: on another provider's session, Metask is listed with the sign-in auth.json holds, and not without one (#488)" {
    var case: Case = undefined;
    try case.initInProcess();
    defer case.deinit();
    const a = case.arena();
    var env: InProcessEnv = .{};
    try env.init((try a.dupeZ(u8, case.home)).ptr);
    defer env.deinit();
    var auth_file = try EnvGuard.set("METACODES_AUTH_FILE", null);
    defer auth_file.restore();
    try case.write("state/config.json", try relayConfig(a, "http://127.0.0.1:9", ""));
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    // No sign-in: Metask is not listed, and nothing leads to a sign-in.
    {
        const app = try relayApp(&case, io_runtime.io());
        defer app.deinit();
        var ui: cc.tui_ui_state.UiState = .{};
        cc.repl_picker_host.open(app, &ui, .unguarded);
        try testing.expectError(error.ProviderNotListed, cursorOnProvider(app, &ui, "metask"));
        try testing.expect(app.model_picker.setup == null);
    }

    // The key `metacodes login` stored: Metask is a route a pick applies,
    // with that key, and the bill moves to the Metask account.
    try cc.core_auth.saveToPath(a, try std.fs.path.join(a, &.{ case.state, "auth.json" }), .{
        .api_key = try a.dupe(u8, "sk-metask-login"),
    });
    const app = try relayApp(&case, io_runtime.io());
    defer app.deinit();
    var ui: cc.tui_ui_state.UiState = .{};
    cc.repl_picker_host.open(app, &ui, .unguarded);
    _ = try cursorOnProvider(app, &ui, "metask");
    var result: cc.repl_picker_host.Result = .ignored;
    for (0..4) |_| {
        result = cc.repl_picker_host.onKey(app, &ui, .enter, .unguarded);
        if (result == .committed) break;
    }
    try testing.expectEqual(cc.repl_picker_host.Result.committed, result);
    try testing.expectEqualStrings("sk-metask-login", app.api_key);
    try testing.expect(std.mem.indexOf(u8, app.model_picker.notice(), "from now on billed to your Metask account") != null);
}

/// Every built-in vendor's key variable: a case that asserts no provider is
/// configured clears them, so the developer's shell decides nothing.
const VENDOR_KEYS = [_][*:0]const u8{
    "OPENAI_API_KEY",     "GEMINI_API_KEY",           "GOOGLE_API_KEY",    "ZAI_API_KEY",
    "GLM_API_KEY",        "Z_AI_API_KEY",             "DEEPSEEK_API_KEY",  "KIMI_API_KEY",
    "MOONSHOT_API_KEY",   "KIMI_CODE_API_KEY",        "DASHSCOPE_API_KEY", "MINIMAX_API_KEY",
    "OPENROUTER_API_KEY", "AWS_BEARER_TOKEN_BEDROCK",
};

test "state .env: a session that started without a key lists no provider, and /model points at /login and this install's .env (#488)" {
    // What the start-up that opens the TUI with nothing configured (#484)
    // would hand App: the historical route, and no key. An empty key binds
    // nothing (credential.resolve), so Metask is not listed either; nor is
    // any vendor, with no key in the environment.
    var case: Case = undefined;
    try case.initInProcess();
    defer case.deinit();
    const a = case.arena();
    var env: InProcessEnv = .{};
    try env.init((try a.dupeZ(u8, case.home)).ptr);
    defer env.deinit();
    var auth_file = try EnvGuard.set("METACODES_AUTH_FILE", null);
    defer auth_file.restore();
    var vendor_guards: [VENDOR_KEYS.len]EnvGuard = undefined;
    var vendor_count: usize = 0;
    defer while (vendor_count > 0) {
        vendor_count -= 1;
        vendor_guards[vendor_count].restore();
    };
    for (VENDOR_KEYS) |name| {
        vendor_guards[vendor_count] = try EnvGuard.set(name, null);
        vendor_count += 1;
    }
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();
    var config = cc.parseArgsForTest(&.{ "metacodes", "--base-url", "http://127.0.0.1:9/v1/messages", "--model", "claude-sonnet-4-6" }, a);
    try testing.expect(config.parse_error == null);
    config.state_root = case.state;
    const app = try App.init(testing.allocator, io_runtime.io(), config, "");
    defer app.deinit();

    var ui: cc.tui_ui_state.UiState = .{};
    cc.repl_picker_host.open(app, &ui, .unguarded);
    try testing.expectEqual(@as(usize, 0), app.model_picker.rowCount());
    // Wide enough that a long scratch path is not broken across rows.
    var buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    _ = cc.repl_model_picker_view.render(&app.model_picker, &writer, cc.tui_theme.monochrome, 1000);
    const text = writer.buffered();
    const env_path = try std.fs.path.join(a, &.{ case.state, ".env" });
    const hint = try std.fmt.allocPrint(a, "no providers configured — /login, or configure {s}", .{env_path});
    testing.expect(std.mem.indexOf(u8, text, hint) != null) catch |err| {
        std.debug.print("missing from the picker: {s}\n{s}\n", .{ hint, text });
        return err;
    };
    try testing.expect(std.mem.indexOf(u8, text, "metask not signed in") == null);
    try testing.expect(std.mem.indexOf(u8, text, "enter apply") == null);
    // Enter applies nothing, and shows no setup.
    try testing.expectEqual(cc.repl_picker_host.Result.ignored, cc.repl_picker_host.onKey(app, &ui, .enter, .unguarded));
    try testing.expect(app.model_picker.setup == null);
}

test "state .env: keys of two providers and no name leave the TUI without a model; a /model pick for every future session is the next start's (#486)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var env: InProcessEnv = .{};
    try env.init((try a.dupeZ(u8, case.home)).ptr);
    defer env.deinit();
    var deepseek_env = try EnvGuard.set("DEEPSEEK_API_KEY", null);
    defer deepseek_env.restore();

    // The relay `config.json` defines and DeepSeek: a key for each in the
    // file, and no METACODES_PROVIDER. The relay's endpoint is a MockServer,
    // so the pick can be followed to a request without reaching a vendor.
    var relay = try harness.MockServer.start(OPENAI_SSE, 0);
    defer relay.stop();
    var decoy = try harness.MockServer.start(OPENAI_SSE, 0);
    defer decoy.stop();
    try case.write("state/config.json", try relayConfig(a, try originOf(a, relay), ""));
    try case.write("state/.env", "HOUSE_RELAY_TOKEN=sk-relay-two\nDEEPSEEK_API_KEY=sk-deepseek-two\n");
    var layer = try cc.app_state_env.load(testing.allocator, case.state, .{
        .keys = &.{
            .{ .name = "HOUSE_RELAY_TOKEN", .provider = "house-relay" },
            .{ .name = "DEEPSEEK_API_KEY", .provider = "deepseek" },
        },
    });
    defer layer.deinit();
    const ids = switch (layer.choice()) {
        .several => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 2), ids.len);

    // `-p` still stops, naming both, and sends nothing.
    const stopped = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try originOf(a, decoy)})}, &.{ "-p", "hi" });
    try testing.expect(stopped.exit_code != 0);
    try expectContains(stopped.stderr, "holds keys for several providers (deepseek, house-relay) and names none");
    try testing.expectEqual(@as(usize, 0), relay.requestCount() + decoy.requestCount());

    // The TUI's start (`main`): no model, the file's layer behind the
    // environment, and the providers it names none of.
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();
    var config = cc.parseArgsForTest(&.{ "metacodes", "--base-url", "http://127.0.0.1:9/v1/messages", "--model", "claude-sonnet-4-6" }, a);
    try testing.expect(config.parse_error == null);
    config.state_root = case.state;
    config.credential_env_fallback = layer.lookup();
    const app = try App.initWithOptions(testing.allocator, io_runtime.io(), config, "", .{
        .route_state = .{ .unbound = .nothing_configured },
        .unchosen_local_providers = ids,
    });
    defer app.deinit();
    try testing.expect(app.unbound() != null);
    var reminder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reminder.deinit();
    try app.writeUnboundReminder(&reminder.writer);
    // By the names /model lists, and no edit-and-restart for keys already there.
    try expectContains(reminder.written(), "  Or use a key in .env:         /model (DeepSeek, House relay)\n");
    try expectAbsent(reminder.written(), "METACODES_PROVIDER");
    try expectAbsent(reminder.written(), "sk-relay-two");
    try expectAbsent(reminder.written(), "sk-deepseek-two");

    // /model lists both as ready; Tab makes the pick every future session's.
    var ui: cc.tui_ui_state.UiState = .{};
    cc.repl_picker_host.open(app, &ui, .unguarded);
    _ = try cursorOnProvider(app, &ui, "deepseek");
    cc.repl_picker_host.close(app, &ui, .unguarded);
    cc.repl_picker_host.open(app, &ui, .unguarded);
    _ = try cursorOnProvider(app, &ui, "house-relay");
    _ = cc.repl_picker_host.onKey(app, &ui, .cycle_scope, .unguarded);
    try testing.expectEqual(cc.repl_model_picker.Scope.global, app.model_picker.scope);
    var result: cc.repl_picker_host.Result = .ignored;
    for (0..5) |_| {
        result = cc.repl_picker_host.onKey(app, &ui, .enter, .unguarded);
        if (result == .committed) break;
    }
    try testing.expectEqual(cc.repl_picker_host.Result.committed, result);
    // Bound, with the file's key, and billed as from `.env`.
    try testing.expect(app.unbound() == null);
    try testing.expectEqual(cc.app_module.route_state_mod.CredentialOrigin.local_config, app.route_state.bound);
    try testing.expectEqualStrings("sk-relay-two", app.api_key);
    const stored = try case.tmp.dir.readFileAlloc(testing.io, "state/config.json", a, .limited(1 << 20));
    try expectContains(stored, "\"global_selection\"");
    // The definition the file named is still there.
    try expectContains(stored, "\"house-relay\"");

    // The next start: the stored default (level 2) decides before the file
    // is asked to, and its key is still the file's.
    const next = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try originOf(a, decoy)})}, &.{ "-p", "hi" });
    _ = try expectOneRequest(next, relay, "/relay/v1/chat/completions", "sk-relay-two");
    try testing.expectEqual(@as(usize, 0), decoy.requestCount());
    try expectAbsent(next.stderr, "holds keys for several providers");
}

test "state .env: a key login says which variable is read before the key it stores, the shell's or the file's, by name (#486)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    // The key check: any key passes.
    var check = try harness.MockServer.startRepeatingStatus("{\"object\":\"list\",\"data\":[]}", "HTTP/1.1 200 OK", "");
    defer check.stop();
    const check_url = try std.fmt.allocPrint(a, "METACODES_KEY_CHECK_URL={s}/compatible-mode/v1/models", .{try originOf(a, check)});
    const env_path = try std.fs.path.join(a, &.{ case.state, ".env" });
    const login = [_][]const u8{ "login", "--provider", "qwen", "--api-key", "sk-stored-qwen" };

    // Nothing else holds a Qwen key: new sessions use the stored one.
    const plain = try case.run(&.{check_url}, &login);
    try testing.expectEqual(@as(i32, 0), plain.exit_code);
    try expectContains(plain.stderr, "Stored the key for Alibaba Qwen.");
    try expectContains(plain.stderr, "New sessions on Alibaba Qwen use it");
    try expectAbsent(plain.stderr, "is used before the stored key");

    // The shell's DASHSCOPE_API_KEY is read first.
    const shell = try case.run(&.{ check_url, "DASHSCOPE_API_KEY=sk-shell-qwen" }, &login);
    try testing.expectEqual(@as(i32, 0), shell.exit_code);
    try expectContains(shell.stderr, "Stored the key for Alibaba Qwen.");
    try expectContains(shell.stderr, "warning: DASHSCOPE_API_KEY is set in your shell and is used before the stored key: unset it to use the key you just stored.");
    try expectAbsent(shell.stderr, "New sessions on Alibaba Qwen use it");

    // So is this install's .env.
    try case.write("state/.env", "DASHSCOPE_API_KEY=sk-file-qwen\n");
    const file = try case.run(&.{check_url}, &login);
    try testing.expectEqual(@as(i32, 0), file.exit_code);
    try expectContains(file.stderr, try std.fmt.allocPrint(a, "warning: DASHSCOPE_API_KEY in {s} is used before the stored key: remove it from that file to use the key you just stored.", .{env_path}));

    // Names only, never a value; and the key was stored each time.
    for ([_]Run{ plain, shell, file }) |run| {
        for ([_][]const u8{ "sk-stored-qwen", "sk-shell-qwen", "sk-file-qwen" }) |value| try expectAbsent(run.stderr, value);
    }
    var stored = (try cc.provider_api_key_store.load(testing.allocator, case.state, cc.provider_ids.Slug.lit("qwen"))).?;
    defer stored.deinit();
    try testing.expectEqualStrings("sk-stored-qwen", stored.secret);
}

test "state .env: login status, for keys of two providers and no name, says to choose in /model (#486)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    try case.write("state/.env", "DEEPSEEK_API_KEY=sk-status-deepseek\nOPENAI_API_KEY=sk-status-openai\n");
    const status = try case.run(&.{}, &.{ "login", "status" });
    try expectContains(status.stderr, try std.fmt.allocPrint(a, "This start uses no provider: {s} holds keys of several (deepseek, openai) and names none. Choose one with /model; Tab there applies it to every future session. Or add METACODES_PROVIDER=<one of them> to it.", .{try std.fs.path.join(a, &.{ case.state, ".env" })}));
    try expectAbsent(status.stderr, "sk-status-");
}
