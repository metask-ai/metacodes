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
//! - `doctor` lists the names, never the values.
//!
//! In process, on a real `App` built with the layer the CLI builds
//! (`Config.credential_env_fallback`): a `/model` pick mid-session and a
//! catalog refresh read their keys from the file, behind the environment.

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
    try case.write("state/config.json", try std.fmt.allocPrint(a,
        \\{{"provider_catalogs": {{"openrouter": {{"models_url": "{s}/api/v1/models", "credential_env": "CATALOG_TOKEN"}}}}}}
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
