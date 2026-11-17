//! L2 evidence for the providers the user defines in `custom_providers`,
//! through the real CLI (`METACODES_TEST_CLI_BIN`) against MockServers
//! standing in for a relay. Nothing reaches the network.
//!
//! A key pasted for one (`login --provider <id>`, `/login <id>`):
//! - is checked at its default channel's model listing, sent the way its
//!   requests send it (an Anthropic listing gets `anthropic-version`), stored
//!   in `keys/<id>.json` with no page, and carried by its next request; a
//!   refused key stores nothing.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;

const testing = std.testing;
const Slug = cc.provider_ids.Slug;

const RELAY_KEY = "sk-relay-paste-42";
const MODELS =
    \\{"object":"list","data":[{"id":"glm-4.6","max_input_tokens":200000,"max_tokens":128000},{"id":"kimi-k2","name":"Kimi K2","context_length":256000},{"id":"qwen3-coder-plus"}]}
;
const OPENAI_SSE =
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n" ++
    "data: [DONE]\n\n";

/// A state root and a working directory under a scratch directory.
const Case = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8,
    state: []const u8,
    work: []const u8,
    cli: []const u8,

    /// Null when the CLI binary is not built for this run.
    fn init(self: *Case) !bool {
        if (builtin.os.tag == .windows) return false;
        const raw_cli = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return false;
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena_state.deinit();
        const a = self.arena_state.allocator();
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        self.root = try a.dupe(u8, root_buf[0..try self.tmp.dir.realPath(testing.io, &root_buf)]);
        for ([_][]const u8{ "state", "work" }) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        self.state = try std.fs.path.join(a, &.{ self.root, "state" });
        self.work = try std.fs.path.join(a, &.{ self.root, "work" });
        self.cli = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, std.mem.span(raw_cli), a);
        return true;
    }

    fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    fn arena(self: *Case) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn read(self: *Case, sub_path: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, sub_path, self.arena(), .limited(1 << 20));
    }

    fn write(self: *Case, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |parent| try self.tmp.dir.createDirPath(testing.io, parent);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn exists(self: *Case, sub_path: []const u8) bool {
        self.tmp.dir.access(testing.io, sub_path, .{}) catch return false;
        return true;
    }

    /// `custom_providers.<id>`, which must be there.
    fn defined(self: *Case, id: []const u8) !std.json.Value {
        return (try self.definition(id)) orelse {
            std.debug.print("custom_providers.{s} is not in config.json\n", .{id});
            return error.NotDefined;
        };
    }

    /// `config.json`'s `custom_providers.<id>`, parsed, or null.
    fn definition(self: *Case, id: []const u8) !?std.json.Value {
        const text = self.read("state/config.json") catch return null;
        const root = try std.json.parseFromSliceLeaky(std.json.Value, self.arena(), text, .{});
        const section = root.object.get("custom_providers") orelse return null;
        return section.object.get(id);
    }

    /// The CLI with a clean environment: no key variables, no probe, no
    /// TinyKG, no advisor, `env` added.
    fn run(self: *Case, env: []const []const u8, args: []const []const u8) !Run {
        const a = self.arena();
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        const base = [_][]const u8{
            "/usr/bin/env",
            "-i",
            try std.fmt.allocPrint(a, "HOME={s}", .{self.root}),
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
        const out = try cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 60_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, self.work);
        return .{ .exit_code = out.exit_code, .stdout = out.stdout, .stderr = out.stderr };
    }

    /// `run`, with `stdin_line` on standard input (through /bin/sh, the
    /// line passed in the environment rather than the command line).
    fn runWithStdin(self: *Case, stdin_line: []const u8, args: []const []const u8) !Run {
        const a = self.arena();
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        const base = [_][]const u8{
            "/usr/bin/env",
            "-i",
            try std.fmt.allocPrint(a, "HOME={s}", .{self.root}),
            "PATH=/usr/bin:/bin",
            "METACODES_KG_AUTOSTART=0",
            "METACODES_JEV_URL=off",
            "METACODES_NO_PROBE=1",
            try std.fmt.allocPrint(a, "PASTED_LINE={s}", .{stdin_line}),
            "/bin/sh",
            "-c",
            "printf '%s\\n' \"$PASTED_LINE\" | \"$@\"",
            "sh",
        };
        for (base) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        for ([_][]const u8{ self.cli, "--state-dir", self.state }) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        try argv.append(a, null);
        const out = try cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 60_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, self.work);
        return .{ .exit_code = out.exit_code, .stdout = out.stdout, .stderr = out.stderr };
    }
};

const Run = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,

    fn expectExit(self: Run, code: i32) !void {
        testing.expectEqual(code, self.exit_code) catch |err| {
            std.debug.print("exit {d}; stdout:\n{s}\nstderr:\n{s}\n", .{ self.exit_code, self.stdout, self.stderr });
            return err;
        };
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n  {s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

fn expectAbsent(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("expected NOT to find:\n  {s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedAbsent;
    }
}

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
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn stringAt(value: std.json.Value, key: []const u8) ![]const u8 {
    const found = value.object.get(key) orelse return error.KeyMissing;
    if (found != .string) return error.NotAString;
    return found.string;
}

/// `name`'s value in `captured`, which must carry it.
fn header(captured: harness.CapturedRequest, name: []const u8) ![]const u8 {
    return headerValue(captured, name) orelse {
        std.debug.print("no {s} header in:\n{s}\n", .{ name, captured.raw });
        return error.HeaderMissing;
    };
}

/// `value.<key>`, which must be there.
fn get(value: std.json.Value, key: []const u8) !std.json.Value {
    if (value != .object) return error.NotAnObject;
    return value.object.get(key) orelse {
        std.debug.print("no \"{s}\" in the JSON\n", .{key});
        return error.KeyMissing;
    };
}

/// `value[index]`, which must be there.
fn item(value: std.json.Value, index: usize) !std.json.Value {
    if (value != .array or index >= value.array.items.len) return error.ItemMissing;
    return value.array.items[index];
}

fn requestAt(server: *harness.MockServer, index: usize) !harness.CapturedRequest {
    return server.requestAt(index) orelse return error.RequestMissing;
}

/// A provider defined by hand, the way a person writes it into `config.json`.
fn defineByHand(case: *Case, id: []const u8, entry: []const u8) !void {
    try case.write("state/config.json", try std.fmt.allocPrint(case.arena(), "{{\"custom_providers\":{{\"{s}\":{s}}}}}", .{ id, entry }));
}

// ── a key pasted for a provider of one's own ─────────────────────────────────

test "a pasted key for a provider of one's own is checked at its listing, stored in its own file, and carried by its requests" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    const a = case.arena();
    {
        var refusing = try harness.MockServer.startWithStatus("{\"error\":{\"message\":\"invalid key\"}}", 0, "HTTP/1.1 401 Unauthorized");
        defer refusing.stop();
        try defineByHand(&case, "relay", try std.fmt.allocPrint(a,
            \\{{"channels":[{{"id":"openai","base_url":"{s}/v1","protocol":"openai_chat"}}],"models":[{{"request_model_id":"glm-4.6"}}]}}
        , .{try originOf(a, refusing)}));
        const refused = try case.runWithStdin("sk-wrong", &.{ "login", "--provider", "relay", "--api-key-stdin" });
        try refused.expectExit(1);
        try expectContains(refused.stderr, "refused this key; nothing was stored");
        try testing.expect(!case.exists("state/keys/relay.json"));
    }

    var server = try harness.MockServer.startCassette(&.{ MODELS, OPENAI_SSE }, 0);
    defer server.stop();
    try defineByHand(&case, "relay", try std.fmt.allocPrint(a,
        \\{{"channels":[{{"id":"openai","base_url":"{s}/v1","protocol":"openai_chat"}}],"models":[{{"request_model_id":"glm-4.6"}}]}}
    , .{try originOf(a, server)}));
    const stored = try case.runWithStdin(RELAY_KEY, &.{ "login", "--provider", "relay", "--api-key-stdin" });
    try stored.expectExit(0);
    try expectContains(stored.stderr, "Checking the key with ");
    try expectContains(stored.stderr, "Stored the key for relay.");
    try expectAbsent(stored.stderr, RELAY_KEY);
    const check = try requestAt(server, 0);
    try testing.expectEqualStrings("GET /v1/models HTTP/1.1", requestLine(check));
    try testing.expectEqualStrings("Bearer " ++ RELAY_KEY, try header(check, "authorization"));

    // Its own file, private, with no page: the key was pasted, not made on one.
    const key_file = try case.read("state/keys/relay.json");
    try expectContains(key_file, "\"kind\":\"api_key\"");
    try expectAbsent(key_file, "\"page\"");
    const key_path = try std.fs.path.joinZ(a, &.{ case.state, "keys", "relay.json" });
    try testing.expectEqual(@as(u32, 0o600), (@import("platform").fs.statMode(key_path.ptr, false) orelse return error.NoMode) & 0o777);
    // config.json names no key.
    try expectAbsent(try case.read("state/config.json"), RELAY_KEY);

    // The next request on that provider carries it.
    const asked = try case.run(&.{}, &.{ "--provider", "relay", "--model", "glm-4.6", "-p", "hi" });
    try asked.expectExit(0);
    const chat = try requestAt(server, 1);
    try testing.expectEqualStrings("POST /v1/chat/completions HTTP/1.1", requestLine(chat));
    try testing.expectEqualStrings("Bearer " ++ RELAY_KEY, try header(chat, "authorization"));
}

test "a key for an Anthropic-speaking provider is checked at its listing with the version header it needs" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    const a = case.arena();
    var server = try harness.MockServer.start(MODELS, 0);
    defer server.stop();
    try defineByHand(&case, "claude-relay", try std.fmt.allocPrint(a,
        \\{{"auth":{{"kind":"api_key_header","header":"x-api-key"}},
        \\  "channels":[{{"id":"anthropic","base_url":"{s}","protocol":"anthropic_messages"}}],"models":[{{"request_model_id":"claude-sonnet-4-6"}}]}}
    , .{try originOf(a, server)}));

    const stored = try case.runWithStdin(RELAY_KEY, &.{ "login", "--provider", "claude-relay", "--api-key-stdin" });
    try stored.expectExit(0);
    const check = server.lastRequest() orelse return error.RequestMissing;
    try testing.expectEqualStrings("GET /v1/models?limit=1000 HTTP/1.1", requestLine(check));
    try testing.expectEqualStrings("2023-06-01", try header(check, "anthropic-version"));
    // Where its requests carry the key, and nowhere else.
    try testing.expectEqualStrings(RELAY_KEY, try header(check, "x-api-key"));
    try testing.expect(headerValue(check, "authorization") == null);
    try testing.expect(case.exists("state/keys/claude-relay.json"));
}
