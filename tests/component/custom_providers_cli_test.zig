//! L2 evidence for the providers the user defines in `custom_providers`,
//! through the real CLI (`METACODES_TEST_CLI_BIN`) against MockServers
//! standing in for a relay. Nothing reaches the network.
//!
//! A key pasted for one (`login --provider <id>`, `/login <id>`):
//! - is checked at its default channel's model listing, sent the way its
//!   requests send it (an Anthropic listing gets `anthropic-version`), stored
//!   in `keys/<id>.json` with no page, and carried by its next request; a
//!   refused key stores nothing.
//!
//! `metacodes providers add|probe|list|remove`:
//! - `add` writes the definition a person would write into
//!   `custom_providers.<id>`, leaves every other key of `config.json` as it
//!   was, and `--check-providers` routes it; a relay that serves two
//!   protocols is one provider with two channels;
//! - an address the endpoint policy refuses (plain http to another machine,
//!   a user name or password in the URL), a built-in id, an id already
//!   taken, and a key variable another provider reads are all refused before
//!   a byte is written;
//! - `probe` asks the model listing with the key sent the way the
//!   provider's requests send it and stores nothing; `add --probe` with a
//!   refused key writes nothing;
//! - `remove` takes the definition, its settings, its stored key and a
//!   default on one of its models;
//! - `--replace` changes what it is given, keeps what was written by hand,
//!   and refuses a new address while a key stored for the old one would
//!   follow it — reading the old address from the file, so a definition
//!   that does not load cannot skip the check.
//!
//! `/providers remove` in the terminal UI takes a defined provider whole, so
//! it does not come back at the next start.

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

// ── metacodes providers ──────────────────────────────────────────────────────

test "providers add writes what a person would write, keeps the rest of config.json, and --check-providers routes it" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    // Another writer's keys, and a hand-written provider with a price.
    const hand_written =
        \\{"theme":"dark","mcp_servers":[{"name":"kg","command":"kgd"}],
        \\ "custom_providers":{"older":{"channels":[{"id":"c","base_url":"https://older.example.com/v1","protocol":"openai_chat"}],
        \\   "models":[{"request_model_id":"m","price":{"currency":"USD","input":2.5}}]}}}
    ;
    try case.write("state/config.json", hand_written);

    const added = try case.run(&.{}, &.{ "providers", "add", "relay", "--base-url", "https://relay.example.com/v1/", "--protocol", "openai_chat", "--model", "glm-4.6", "--model", "kimi-k2", "--display-name", "House relay" });
    try added.expectExit(0);
    try expectContains(added.stderr, "Added relay in ");
    try expectContains(added.stderr, "This takes effect at the next start");
    try expectContains(added.stderr, "login --provider relay");

    const relay = try case.defined("relay");
    try testing.expectEqualStrings("House relay", try stringAt(relay, "display_name"));
    // No auth block, no variable: the defaults a person leaves out.
    try testing.expect(relay.object.get("auth") == null);
    try testing.expect(relay.object.get("env_aliases") == null);
    const channels = (try get(relay, "channels")).array.items;
    try testing.expectEqual(@as(usize, 1), channels.len);
    try testing.expectEqualStrings("openai", try stringAt(channels[0], "id"));
    // The trailing slash is not part of the base.
    try testing.expectEqualStrings("https://relay.example.com/v1", try stringAt(channels[0], "base_url"));
    try testing.expectEqualStrings("openai_chat", try stringAt(channels[0], "protocol"));
    const models = (try get(relay, "models")).array.items;
    try testing.expectEqual(@as(usize, 2), models.len);
    try testing.expectEqualStrings("kimi-k2", try stringAt(models[1], "request_model_id"));

    const text = try case.read("state/config.json");
    const root = try std.json.parseFromSliceLeaky(std.json.Value, case.arena(), text, .{});
    try testing.expectEqualStrings("dark", try stringAt(root, "theme"));
    try testing.expectEqualStrings("kgd", try stringAt(try item(try get(root, "mcp_servers"), 0), "command"));
    const older = try get(try get(root, "custom_providers"), "older");
    try testing.expectEqual(@as(f64, 2.5), (try get(try get(try item(try get(older, "models"), 0), "price"), "input")).float);
    // The new member follows the one that was there.
    try testing.expectEqualStrings("older", (try get(root, "custom_providers")).object.keys()[0]);

    const checked = try case.run(&.{}, &.{"--check-providers"});
    try checked.expectExit(0);
    try expectContains(checked.stderr, "relay/openai [openai_chat] model=glm-4.6\n  endpoint https://relay.example.com/v1/chat/completions");
    try expectContains(checked.stderr, "relay/openai [openai_chat] model=kimi-k2");

    const listed = try case.run(&.{}, &.{ "providers", "list" });
    try listed.expectExit(0);
    try expectContains(listed.stdout, "relay  House relay\n  openai  openai_chat  https://relay.example.com/v1\n  models: glm-4.6, kimi-k2\n");
    try expectContains(listed.stdout, "key:    none (`");
    try expectContains(listed.stdout, "older\n");
}

test "a relay serving two protocols becomes one provider with two channels" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    const added = try case.run(&.{}, &.{ "providers", "add", "relay", "--base-url", "https://relay.example.com/v1", "--protocol", "openai_chat", "--protocol", "anthropic_messages", "--protocol", "openai_responses=https://responses.example.com/api/v1", "--model", "glm-4.6" });
    try added.expectExit(0);
    const channels = (try get(try case.defined("relay"), "channels")).array.items;
    try testing.expectEqual(@as(usize, 3), channels.len);
    try testing.expectEqualStrings("https://relay.example.com/v1", try stringAt(channels[0], "base_url"));
    // The Anthropic root drops the /v1 its transport appends.
    try testing.expectEqualStrings("anthropic", try stringAt(channels[1], "id"));
    try testing.expectEqualStrings("https://relay.example.com", try stringAt(channels[1], "base_url"));
    try testing.expectEqualStrings("https://responses.example.com/api/v1", try stringAt(channels[2], "base_url"));

    const checked = try case.run(&.{}, &.{"--check-providers"});
    try checked.expectExit(0);
    try expectContains(checked.stderr, "relay/openai [openai_chat] model=glm-4.6\n  endpoint https://relay.example.com/v1/chat/completions");
    try expectContains(checked.stderr, "relay/anthropic [anthropic_messages] model=glm-4.6\n  endpoint https://relay.example.com/v1/messages");
    try expectContains(checked.stderr, "relay/responses [openai_responses] model=glm-4.6\n  endpoint https://responses.example.com/api/v1/responses");
}

test "an Anthropic address with its /v1 is stored at its root, with the header --auth names" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    const added = try case.run(&.{}, &.{ "providers", "add", "claude-relay", "--base-url", "https://relay.example.com/v1/", "--protocol", "anthropic_messages", "--auth", "header:x-api-key", "--model", "claude-sonnet-4-6" });
    try added.expectExit(0);
    const relay = try case.defined("claude-relay");
    const auth = try get(relay, "auth");
    try testing.expectEqualStrings("api_key_header", try stringAt(auth, "kind"));
    try testing.expectEqualStrings("x-api-key", try stringAt(auth, "header"));
    const channel = try item(try get(relay, "channels"), 0);
    try testing.expectEqualStrings("https://relay.example.com", try stringAt(channel, "base_url"));
}

test "an address, an id or a key variable that cannot be is refused before a byte is written" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    const Refusal = struct { args: []const []const u8, says: []const u8 };
    const refusals = [_]Refusal{
        .{ .args = &.{ "providers", "add", "relay", "--base-url", "http://relay.example.com/v1", "--protocol", "openai_chat", "--model", "m" }, .says = "plain http goes only to this machine" },
        .{ .args = &.{ "providers", "add", "relay", "--base-url", "https://user:pw@relay.example.com/v1", "--protocol", "openai_chat", "--model", "m" }, .says = "user name or password" },
        .{ .args = &.{ "providers", "add", "relay", "--base-url", "https://relay.example.com/a%2Fb", "--protocol", "openai_chat", "--model", "m" }, .says = "%-escapes" },
        .{ .args = &.{ "providers", "add", "google", "--base-url", "https://relay.example.com/v1", "--protocol", "openai_chat", "--model", "m" }, .says = "Google Gemini, a provider metacodes ships" },
        .{ .args = &.{ "providers", "add", "Relay", "--base-url", "https://relay.example.com/v1", "--protocol", "openai_chat", "--model", "m" }, .says = "cannot be an id" },
        .{ .args = &.{ "providers", "add", "relay", "--base-url", "https://relay.example.com/v1", "--protocol", "grpc", "--model", "m" }, .says = "--protocol grpc" },
        .{ .args = &.{ "providers", "add", "relay", "--base-url", "https://relay.example.com/v1", "--protocol", "openai_chat", "--model", "m", "--key-env", "OPENAI_API_KEY" }, .says = "OpenAI already reads it" },
        .{ .args = &.{ "providers", "add", "relay", "--base-url", "https://relay.example.com/v1", "--protocol", "openai_chat", "--model", "m", "--key-env", "RELAY_BASE_URL" }, .says = "_URL is never read" },
        .{ .args = &.{ "providers", "add", "relay", "--base-url", "https://relay.example.com/v1", "--protocol", "openai_chat" }, .says = "name at least one model" },
        // Refused before the probe is sent: no terminal to pick at.
        .{ .args = &.{ "providers", "add", "relay", "--base-url", "https://relay.example.com/v1", "--protocol", "openai_chat", "--probe" }, .says = "--probe without a terminal" },
    };
    for (refusals) |refusal| {
        const out = try case.run(&.{}, refusal.args);
        out.expectExit(2) catch |err| {
            std.debug.print("args: {s}\n", .{try std.mem.join(case.arena(), " ", refusal.args)});
            return err;
        };
        try expectContains(out.stderr, refusal.says);
        // Not created, not even empty.
        try testing.expect(!case.exists("state/config.json"));
    }

    // An id that is taken is not overwritten without --replace.
    try (try case.run(&.{}, &.{ "providers", "add", "relay", "--base-url", "https://relay.example.com/v1", "--protocol", "openai_chat", "--model", "m" })).expectExit(0);
    const before = try case.read("state/config.json");
    const again = try case.run(&.{}, &.{ "providers", "add", "relay", "--base-url", "https://other.example.com/v1", "--protocol", "openai_chat", "--model", "n" });
    try again.expectExit(2);
    try expectContains(again.stderr, "already defines 'relay'");
    try testing.expectEqualStrings(before, try case.read("state/config.json"));
}

test "probe asks the listing with the key sent as requests send it, and stores nothing" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    const a = case.arena();
    var server = try harness.MockServer.startCassette(&.{ MODELS, MODELS }, 0);
    defer server.stop();
    const origin = try originOf(a, server);

    const base = try std.fmt.allocPrint(a, "{s}/v1", .{origin});
    try (try case.run(&.{}, &.{ "providers", "add", "relay", "--base-url", base, "--protocol", "openai_chat", "--model", "glm-4.6", "--key-env", "RELAY_KEY" })).expectExit(0);
    const before = try case.read("state/config.json");

    const by_id = try case.run(&.{"RELAY_KEY=" ++ RELAY_KEY}, &.{ "providers", "probe", "relay" });
    try by_id.expectExit(0);
    try expectContains(by_id.stdout, "relay/openai: GET ");
    try expectContains(by_id.stdout, "/v1/models lists 3 model(s)");
    try expectContains(by_id.stdout, "kimi-k2");
    try expectContains(by_id.stdout, "Kimi K2  ctx 256000");
    try expectContains(by_id.stdout, "Asked with RELAY_KEY from the shell, sent as a bearer token.");
    try expectAbsent(by_id.stdout, RELAY_KEY);
    const listing = try requestAt(server, 0);
    try testing.expectEqualStrings("GET /v1/models HTTP/1.1", requestLine(listing));
    try testing.expectEqualStrings("Bearer " ++ RELAY_KEY, try header(listing, "authorization"));
    try testing.expect(std.mem.startsWith(u8, try header(listing, "user-agent"), "metacodes/"));
    try testing.expectEqualStrings(before, try case.read("state/config.json"));

    // An address not yet defined, as Anthropic lists models: its root, its
    // version header, the key from stdin.
    const anthropic = try case.runWithStdin(RELAY_KEY, &.{ "providers", "probe", "--base-url", base, "--protocol", "anthropic_messages", "--api-key-stdin" });
    try anthropic.expectExit(0);
    try expectContains(anthropic.stdout, "anthropic_messages: GET ");
    const second = try requestAt(server, 1);
    try testing.expectEqualStrings("GET /v1/models?limit=1000 HTTP/1.1", requestLine(second));
    try testing.expectEqualStrings("2023-06-01", try header(second, "anthropic-version"));
    try testing.expectEqualStrings("Bearer " ++ RELAY_KEY, try header(second, "authorization"));
    try testing.expectEqualStrings(before, try case.read("state/config.json"));
}

test "add --probe writes what the listing says; a refused key writes nothing" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    const a = case.arena();
    {
        var refusing = try harness.MockServer.startWithStatus("{\"error\":{\"message\":\"invalid key\"}}", 0, "HTTP/1.1 401 Unauthorized");
        defer refusing.stop();
        const base = try std.fmt.allocPrint(a, "{s}/v1", .{try originOf(a, refusing)});
        const refused = try case.run(&.{"RELAY_KEY=sk-wrong"}, &.{ "providers", "add", "relay", "--base-url", base, "--protocol", "openai_chat", "--key-env", "RELAY_KEY", "--probe", "--model", "glm-4.6" });
        try refused.expectExit(1);
        try expectContains(refused.stderr, "answered 401: it refused the key; nothing was written");
        try expectAbsent(refused.stderr, "sk-wrong");
        try testing.expect(!case.exists("state/config.json"));
    }
    var server = try harness.MockServer.start(MODELS, 0);
    defer server.stop();
    const base = try std.fmt.allocPrint(a, "{s}/v1", .{try originOf(a, server)});
    const added = try case.run(&.{"RELAY_KEY=" ++ RELAY_KEY}, &.{ "providers", "add", "relay", "--base-url", base, "--protocol", "openai_chat", "--key-env", "RELAY_KEY", "--probe", "--model", "glm-4.6", "--model", "unlisted-model" });
    try added.expectExit(0);
    try expectContains(added.stderr, "warning: the endpoint does not list unlisted-model; it is written as given");
    const relay = try case.defined("relay");
    const models = (try get(relay, "models")).array.items;
    // The limits the listing reported are written with the model.
    const limits = try get(models[0], "limits");
    try testing.expectEqual(@as(i64, 200_000), (try get(limits, "context_window")).integer);
    try testing.expectEqual(@as(i64, 128_000), (try get(limits, "max_output_tokens")).integer);
    try testing.expect(models[1].object.get("limits") == null);
    try testing.expectEqualStrings("RELAY_KEY", try stringAt(try item(try get(relay, "env_aliases"), 0), "name"));
}

test "remove takes the definition, its settings, its stored key and a default on its models" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    const a = case.arena();
    var server = try harness.MockServer.start(MODELS, 0);
    defer server.stop();
    const base = try std.fmt.allocPrint(a, "{s}/v1", .{try originOf(a, server)});
    try (try case.run(&.{}, &.{ "providers", "add", "relay", "--base-url", base, "--protocol", "openai_chat", "--model", "glm-4.6" })).expectExit(0);
    try (try case.runWithStdin(RELAY_KEY, &.{ "login", "--provider", "relay", "--api-key-stdin" })).expectExit(0);

    // Settings and a stored default on one of its models, as the TUI leaves
    // them (`/providers disable`, `/model` with Tab).
    {
        // The host frees what the store reads: one allocator for both.
        var store = try cc.provider_config_store.Store.initHome(testing.allocator, case.state);
        defer store.deinit();
        _ = try cc.provider_config_store.setProviderEnabled(&store, Slug.lit("relay"), true, null);
        const host = try cc.provider_host.Host.create(testing.allocator);
        defer host.destroy();
        host.adoptDurableState(&store);
        const offer = for (host.kernel.catalogSnapshot().items()) |*candidate| {
            if (candidate.provider_id.eqlText("relay")) break candidate;
        } else return error.OfferMissing;
        _ = try cc.provider_config_store.setGlobalSelection(&store, cc.provider_selection.RuntimeSelection.pinned(offer.offer_id, offer.offer_revision, .global), null, null);
    }
    const text_before = try case.read("state/config.json");
    try expectContains(text_before, "global_selection");

    const removed = try case.run(&.{}, &.{ "providers", "remove", "relay" });
    try removed.expectExit(0);
    try expectContains(removed.stderr, "Removed relay from ");
    try expectContains(removed.stderr, "Removed its settings (providers.relay).");
    try expectContains(removed.stderr, "Forgot the default model, which was one of its.");
    try expectContains(removed.stderr, "Removed its stored key (");
    try expectContains(removed.stderr, "This takes effect at the next start");
    try testing.expect(!case.exists("state/keys/relay.json"));
    try testing.expect((try case.definition("relay")) == null);
    const after = try case.read("state/config.json");
    try expectAbsent(after, "\"relay\"");
    try expectAbsent(after, "global_selection");

    const checked = try case.run(&.{}, &.{"--check-providers"});
    try checked.expectExit(0);
    try expectAbsent(checked.stderr, "relay/");
    const again = try case.run(&.{}, &.{ "providers", "remove", "relay" });
    try again.expectExit(1);
    try expectContains(again.stderr, "No provider 'relay' is configured here; nothing to remove.");
    const shipped = try case.run(&.{}, &.{ "providers", "remove", "deepseek" });
    try shipped.expectExit(2);
    try expectContains(shipped.stderr, "a provider metacodes ships and cannot be removed");
}

test "--replace changes what it is given, keeps what was written by hand, and keeps a stored key at its address" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    try case.write("state/config.json",
        \\{"custom_providers":{"relay":{"display_name":"Old name",
        \\  "channels":[{"id":"openai","base_url":"https://relay.example.com/v1","protocol":"openai_chat","region":"eu"}],
        \\  "models":[{"request_model_id":"glm-4.6","price":{"currency":"EUR","input":2.5}}]}}}
    );
    const renamed = try case.run(&.{}, &.{ "providers", "add", "relay", "--replace", "--display-name", "New name" });
    try renamed.expectExit(0);
    try expectContains(renamed.stderr, "Changed relay in ");
    const relay = try case.defined("relay");
    try testing.expectEqualStrings("New name", try stringAt(relay, "display_name"));
    try testing.expectEqualStrings("eu", try stringAt(try item(try get(relay, "channels"), 0), "region"));
    try testing.expectEqual(@as(f64, 2.5), (try get(try get(try item(try get(relay, "models"), 0), "price"), "input")).float);

    // A key stored for the old address does not follow it to a new one.
    try case.write("state/keys/relay.json", "{\"schema_version\":1,\"kind\":\"api_key\",\"key\":\"sk-x\",\"stored_at\":1}");
    const before = try case.read("state/config.json");
    const moved = try case.run(&.{}, &.{ "providers", "add", "relay", "--replace", "--base-url", "https://elsewhere.example.com/v1", "--protocol", "openai_chat" });
    try moved.expectExit(2);
    try expectContains(moved.stderr, "it would now go to https://elsewhere.example.com");
    try expectContains(moved.stderr, "logout --provider relay");
    try testing.expectEqualStrings(before, try case.read("state/config.json"));
    // At the same address, a change of path is fine.
    const same_host = try case.run(&.{}, &.{ "providers", "add", "relay", "--replace", "--base-url", "https://relay.example.com/v2", "--protocol", "openai_chat" });
    try same_host.expectExit(0);
    try testing.expectEqualStrings("https://relay.example.com/v2", try stringAt(try item(try get(try case.defined("relay"), "channels"), 0), "base_url"));

    const nothing = try case.run(&.{}, &.{ "providers", "add", "missing", "--replace", "--display-name", "X" });
    try nothing.expectExit(2);
    try expectContains(nothing.stderr, "there is no 'missing'");
}

test "--replace keeps a stored key at its address even when the definition does not load" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    // No models: the definition does not load, so the loaded registry knows
    // nothing of where its key was meant to go. The file still says.
    try defineByHand(&case, "relay",
        \\{"channels":[{"id":"openai","base_url":"https://relay.example.com/v1","protocol":"openai_chat"}]}
    );
    try case.write("state/keys/relay.json", "{\"schema_version\":1,\"kind\":\"api_key\",\"key\":\"sk-x\",\"stored_at\":1}");
    const before = try case.read("state/config.json");
    const moved = try case.run(&.{}, &.{ "providers", "add", "relay", "--replace", "--base-url", "https://elsewhere.example.com/v1", "--protocol", "openai_chat", "--model", "glm-4.6" });
    try moved.expectExit(2);
    try expectContains(moved.stderr, "it would now go to https://elsewhere.example.com");
    try testing.expectEqualStrings(before, try case.read("state/config.json"));

    // At the address it was stored for, the same replace mends it.
    const mended = try case.run(&.{}, &.{ "providers", "add", "relay", "--replace", "--base-url", "https://relay.example.com/v1", "--protocol", "openai_chat", "--model", "glm-4.6" });
    try mended.expectExit(0);
    const checked = try case.run(&.{}, &.{"--check-providers"});
    try checked.expectExit(0);
    try expectContains(checked.stderr, "relay/openai [openai_chat] model=glm-4.6");

    // Channels that cannot be read say nowhere: every address is new to the key.
    try defineByHand(&case, "relay", "{\"channels\":\"unreadable\",\"models\":[{\"request_model_id\":\"m\"}]}");
    const unknown = try case.run(&.{}, &.{ "providers", "add", "relay", "--replace", "--base-url", "https://relay.example.com/v1", "--protocol", "openai_chat" });
    try unknown.expectExit(2);
    try expectContains(unknown.stderr, "a key is stored for 'relay'");
    try testing.expect(case.exists("state/keys/relay.json"));
}

test "providers --help is written to stdout" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    const help = try case.run(&.{}, &.{ "providers", "--help" });
    try help.expectExit(0);
    try expectContains(help.stdout, "usage: metacodes providers add <id> --base-url <url> --protocol <wire>");
    try testing.expectEqual(@as(usize, 0), help.stderr.len);
}

// ── /providers remove in the terminal UI ─────────────────────────────────────

test "the TUI's /providers remove takes a defined provider whole, and a built-in one's settings only" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    const a = case.arena();
    try (try case.run(&.{}, &.{ "providers", "add", "relay", "--base-url", "https://relay.example.com/v1", "--protocol", "openai_chat", "--model", "glm-4.6" })).expectExit(0);
    try case.write("state/keys/relay.json", "{\"schema_version\":1,\"kind\":\"api_key\",\"key\":\"sk-x\",\"stored_at\":1}");

    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();
    var config = cc.parseArgsForTest(&.{"metacodes"}, a);
    config.state_root = case.state;
    const app = try cc.app_module.App.initWithOptions(testing.allocator, io_runtime.io(), config, "", .{ .route_state = .{ .unbound = .nothing_configured } });
    defer app.deinit();
    try app.setProviderEnabled(Slug.lit("deepseek"), false);

    const removed = try app.removeProviderConfiguration(Slug.lit("relay"));
    try testing.expect(removed.definition);
    try testing.expect(removed.key);
    try testing.expect((try case.definition("relay")) == null);
    try testing.expect(!case.exists("state/keys/relay.json"));

    const shipped = try app.removeProviderConfiguration(Slug.lit("deepseek"));
    try testing.expect(!shipped.definition);
    try expectAbsent(try case.read("state/config.json"), "\"deepseek\"");
}

// ── a coding plan of one's own ───────────────────────────────────────────────

test "a provider added as a subscription plan warns a start with nobody at the keyboard, once" {
    var case: Case = undefined;
    if (!try case.init()) return error.SkipZigTest;
    defer case.deinit();
    const a = case.arena();
    var server = try harness.MockServer.startCassette(&.{ OPENAI_SSE, OPENAI_SSE }, 0);
    defer server.stop();
    const base = try std.fmt.allocPrint(a, "{s}/v1", .{try originOf(a, server)});
    const added = try case.run(&.{}, &.{ "providers", "add", "coding-plan", "--display-name", "House Coding Plan", "--base-url", base, "--protocol", "openai_chat", "--model", "glm-4.6", "--key-env", "PLAN_KEY", "--subscription-plan" });
    try added.expectExit(0);
    try testing.expect((try get(try case.defined("coding-plan"), "subscription_plan")).bool);
    const listed = try case.run(&.{}, &.{ "providers", "list" });
    try expectContains(listed.stdout, "coding-plan  House Coding Plan  (subscription plan)\n");

    const warned = try case.run(&.{"PLAN_KEY=sk-plan"}, &.{ "--provider", "coding-plan", "--model", "glm-4.6", "-p", "hi" });
    try warned.expectExit(0);
    const line = "warning: House Coding Plan is a subscription plan for interactive use";
    try expectContains(warned.stderr, line);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, warned.stderr, line));

    // A provider not marked says nothing.
    try (try case.run(&.{}, &.{ "providers", "add", "metered", "--base-url", base, "--protocol", "openai_chat", "--model", "glm-4.6", "--key-env", "METERED_KEY" })).expectExit(0);
    const quiet = try case.run(&.{"METERED_KEY=sk-metered"}, &.{ "--provider", "metered", "--model", "glm-4.6", "-p", "hi" });
    try quiet.expectExit(0);
    try expectAbsent(quiet.stderr, "subscription plan");
}
