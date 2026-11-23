//! L2 for #489: named presets (`--preset`, `METACODES_PRESET`) and the preset
//! a directory remembers, through the real CLI.
//!
//! The CLI (`METACODES_TEST_CLI_BIN`) runs `-p` with a state root of its own,
//! in an environment holding only what each case sets (the capture starts a
//! POSIX child with an empty one), against MockServers on the loopback.
//! Every route is a provider `config.json` defines (`custom_providers`) whose
//! endpoint is a MockServer, so whatever a start decides, no request can
//! reach a real vendor and no real key is read.
//!
//! - `--preset a` reaches A with A's key and A's reasoning effort;
//!   `METACODES_PRESET=b` reaches B; the flag wins over the variable;
//! - `--preset a --model <other>` (and `--reasoning-effort`) change that run
//!   only: config.json is byte for byte what it was, and the next start is
//!   on the preset again; `--provider` sets the preset aside;
//! - a preset whose provider has no key is not replaced by another route:
//!   `-p` stops with that provider's help and sends nothing;
//! - directories X→a and Y→b, each a repository (a start in Y's
//!   subdirectory is keyed by Y), use a and b; Z, which remembers none, uses
//!   the `/model` default; nothing is created inside X, Y or Z;
//! - editing preset a in config.json changes what X uses on the next start;
//! - an unknown preset, named or remembered, stops `-p` non-zero before any
//!   request and lists the presets config.json defines;
//! - `.env`'s `METACODES_PRESET` ranks below a stored `/model` default and
//!   above the provider the same file configures;
//! - `login status` shows the seven levels and which one decided.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");

const testing = std.testing;

const OPENAI_SSE =
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n" ++
    "data: [DONE]\n\n";

/// Three providers on the OpenAI wire, each at its own MockServer, and two
/// presets: `a` (A's `a-model`, reasoning effort high) and `b` (B's
/// `b-model`). `extra` goes into the top-level object.
fn presetConfig(arena: std.mem.Allocator, mocks: *const Mocks, extra: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\{{"custom_providers": {{
        \\  "prov-a": {{"display_name": "Prov A", "credential_kinds": ["api_key"],
        \\    "env_aliases": [{{"name": "PROV_A_TOKEN", "kind": "api_key", "canonical": true}}],
        \\    "channels": [{{"id": "primary", "base_url": "{s}/a/v1", "protocol": "openai_chat"}}],
        \\    "models": [{{"request_model_id": "a-model", "display_name": "A model"}},
        \\               {{"request_model_id": "a-model-2", "display_name": "A model 2"}}]}},
        \\  "prov-b": {{"display_name": "Prov B", "credential_kinds": ["api_key"],
        \\    "env_aliases": [{{"name": "PROV_B_TOKEN", "kind": "api_key", "canonical": true}}],
        \\    "channels": [{{"id": "primary", "base_url": "{s}/b/v1", "protocol": "openai_chat"}}],
        \\    "models": [{{"request_model_id": "b-model", "display_name": "B model"}}]}},
        \\  "prov-c": {{"display_name": "Prov C", "credential_kinds": ["api_key"],
        \\    "env_aliases": [{{"name": "PROV_C_TOKEN", "kind": "api_key", "canonical": true}}],
        \\    "channels": [{{"id": "primary", "base_url": "{s}/c/v1", "protocol": "openai_chat"}}],
        \\    "models": [{{"request_model_id": "c-model", "display_name": "C model"}}]}}}},
        \\ "presets": {{
        \\  "a": {{"target": {{"kind": "auto_route", "selector": "a-model"}}, "controls": {{"reasoning_effort": {{"text": "high"}}}}}},
        \\  "b": {{"target": {{"kind": "auto_route", "selector": "b-model"}}}}}}{s}}}
    , .{ try originOf(arena, mocks.a), try originOf(arena, mocks.b), try originOf(arena, mocks.c), extra });
}

/// What lets `/model`'s default be told apart: a `global_selection` of C.
const stored_default_of_c =
    \\, "global_selection": {"target": {"kind": "auto_route", "selector": "c-model"}, "scope": "global"}
;

/// Every provider's key, and the client's request line in the log.
const keys = [_][]const u8{ "PROV_A_TOKEN=sk-a", "PROV_B_TOKEN=sk-b", "PROV_C_TOKEN=sk-c", "METACODES_LOG=openai:info" };

/// Every request a mock receives gets the same answer.
const replies = [_][]const u8{OPENAI_SSE};

const Mocks = struct {
    a: *harness.MockServer,
    b: *harness.MockServer,
    c: *harness.MockServer,

    /// Each serves any number of requests (a case starts several times).
    fn start() !Mocks {
        const a = try harness.MockServer.startCassette(&replies, 0);
        errdefer a.stop();
        const b = try harness.MockServer.startCassette(&replies, 0);
        errdefer b.stop();
        return .{ .a = a, .b = b, .c = try harness.MockServer.startCassette(&replies, 0) };
    }

    fn stop(self: *Mocks) void {
        self.a.stop();
        self.b.stop();
        self.c.stop();
    }

    fn total(self: *const Mocks) usize {
        return self.a.requestCount() + self.b.requestCount() + self.c.requestCount();
    }
};

const Run = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
};

/// One scratch install: a state root, working directories and a home, and
/// the CLI to run there.
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
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena_state.deinit();
        const a = self.arena_state.allocator();
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        self.root = try a.dupe(u8, root_buf[0..try self.tmp.dir.realPath(testing.io, &root_buf)]);
        for ([_][]const u8{ "state", "work", "home" }) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        self.state = try std.fs.path.join(a, &.{ self.root, "state" });
        self.work = try std.fs.path.join(a, &.{ self.root, "work" });
        self.home = try std.fs.path.join(a, &.{ self.root, "home" });
        self.cli = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, std.mem.span(raw_cli), a);
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

    fn read(self: *Case, sub_path: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(testing.io, sub_path, self.arena(), .limited(1 << 20));
    }

    /// `<root>/<sub_path>`, absolute.
    fn path(self: *Case, sub_path: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena(), &.{ self.root, sub_path });
    }

    /// `metacodes --state-dir <state> args…` in `work`.
    fn run(self: *Case, env: []const []const u8, args: []const []const u8) !Run {
        return self.runIn(self.work, env, args);
    }

    /// `metacodes --state-dir <state> args…` in `cwd`, with only `env` (and
    /// a home, a PATH, no TinyKG start, no advisor, no model probe) set.
    fn runIn(self: *Case, cwd: []const u8, env: []const []const u8, args: []const []const u8) !Run {
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
            cwd,
        );
        return .{ .exit_code = out.exit_code, .stdout = out.stdout, .stderr = out.stderr };
    }

    /// Every path under `<root>/<sub_path>`, sorted, one per line.
    fn listing(self: *Case, sub_path: []const u8) ![]const u8 {
        const a = self.arena();
        var dir = try self.tmp.dir.openDir(testing.io, sub_path, .{ .iterate = true });
        defer dir.close(testing.io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        var paths: std.ArrayList([]const u8) = .empty;
        while (try walker.next(testing.io)) |entry| try paths.append(a, try a.dupe(u8, entry.path));
        std.mem.sort([]const u8, paths.items, {}, struct {
            fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.less);
        return std.mem.join(a, "\n", paths.items);
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

/// The run succeeded, `server` has now seen `count` requests, and the last
/// is `POST <path>` with `Authorization: Bearer <key>` for `model`.
fn expectRequest(run: Run, server: *harness.MockServer, count: usize, path: []const u8, key: []const u8, model: []const u8) !void {
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ run.exit_code, run.stderr });
    try testing.expectEqual(@as(i32, 0), run.exit_code);
    try testing.expectEqual(count, server.requestCount());
    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    var line_buf: [256]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&line_buf, "POST {s} HTTP/1.1", .{path}), requestLine(captured));
    var auth_buf: [256]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key}), headerValue(captured, "authorization") orelse "");
    var model_buf: [128]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&model_buf, "\"{s}\"", .{model}), captured.jsonField("model") orelse "");
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

test "presets: --preset a reaches A with its key and reasoning effort; METACODES_PRESET=b reaches B (#489)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var mocks = try Mocks.start();
    defer mocks.stop();
    // A /model default of C: a preset named at start outranks it.
    try case.write("state/config.json", try presetConfig(a, &mocks, stored_default_of_c));

    const by_flag = try case.run(&keys, &.{ "--preset", "a", "-p", "hi" });
    try expectRequest(by_flag, mocks.a, 1, "/a/v1/chat/completions", "sk-a", "a-model");
    try expectContains(by_flag.stderr, "reasoning_effort=high");

    const by_env = try case.run(&(keys ++ [_][]const u8{"METACODES_PRESET=b"}), &.{ "-p", "hi" });
    try expectRequest(by_env, mocks.b, 1, "/b/v1/chat/completions", "sk-b", "b-model");

    // The flag wins over the variable.
    const both = try case.run(&(keys ++ [_][]const u8{"METACODES_PRESET=b"}), &.{ "--preset", "a", "-p", "hi" });
    try expectRequest(both, mocks.a, 2, "/a/v1/chat/completions", "sk-a", "a-model");
    try testing.expectEqual(@as(usize, 1), mocks.b.requestCount());
    try testing.expectEqual(@as(usize, 0), mocks.c.requestCount());

    // A preset names its route as --provider does: without A's key, the run
    // stops with A's help instead of falling to the /model default.
    const keyless = try case.run(&.{ "PROV_B_TOKEN=sk-b", "PROV_C_TOKEN=sk-c" }, &.{ "--preset", "a", "-p", "hi" });
    try testing.expect(keyless.exit_code != 0);
    try expectContains(keyless.stderr, "Authentication required for provider 'prov-a'.");
    try expectContains(keyless.stderr, "PROV_A_TOKEN");
    try testing.expectEqual(@as(usize, 3), mocks.total());
}

test "presets: a flag changes one field for that run and the stored preset stays as it was (#489)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var mocks = try Mocks.start();
    defer mocks.stop();
    try case.write("state/config.json", try presetConfig(a, &mocks, ""));
    const before = try case.read("state/config.json");

    const other_model = try case.run(&keys, &.{ "--preset", "a", "--model", "a-model-2", "--reasoning-effort", "low", "-p", "hi" });
    try expectRequest(other_model, mocks.a, 1, "/a/v1/chat/completions", "sk-a", "a-model-2");
    try expectContains(other_model.stderr, "reasoning_effort=low");
    try testing.expectEqualStrings(before, try case.read("state/config.json"));

    // The next start without the flags is on the preset again.
    const again = try case.run(&keys, &.{ "--preset", "a", "-p", "hi" });
    try expectRequest(again, mocks.a, 2, "/a/v1/chat/completions", "sk-a", "a-model");
    try expectContains(again.stderr, "reasoning_effort=high");

    // `--provider` names a route of its own (level 1): the preset is set
    // aside, its reasoning effort included.
    const named = try case.run(&keys, &.{ "--preset", "a", "--provider", "prov-b", "-p", "hi" });
    try expectRequest(named, mocks.b, 1, "/b/v1/chat/completions", "sk-b", "b-model");
    try expectAbsent(named.stderr, "reasoning_effort=high");
    try testing.expectEqualStrings(before, try case.read("state/config.json"));
}

test "presets: directories X and Y remember a and b, Z uses the /model default, and none gets a file (#489)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var mocks = try Mocks.start();
    defer mocks.stop();
    // Three repositories (the scratch directory sits inside a checkout, so a
    // directory with no `.git` of its own would be keyed by that checkout).
    for ([_][]const u8{ "work/x/.git", "work/y/.git", "work/y/src/deep", "work/z/.git" }) |dir| try case.tmp.dir.createDirPath(testing.io, dir);
    const x = try case.path("work/x");
    const y = try case.path("work/y");
    try case.write("state/config.json", try presetConfig(a, &mocks, try std.fmt.allocPrint(a,
        \\, "directory_presets": {{"{s}": "a", "{s}/": "b"}}{s}
    , .{ x, y, stored_default_of_c })));
    const untouched = try case.listing("work");

    try expectRequest(try case.runIn(x, &keys, &.{ "-p", "hi" }), mocks.a, 1, "/a/v1/chat/completions", "sk-a", "a-model");
    // Below Y's root, Y's entry (written with a trailing separator) applies.
    try expectRequest(try case.runIn(try case.path("work/y/src/deep"), &keys, &.{ "-p", "hi" }), mocks.b, 1, "/b/v1/chat/completions", "sk-b", "b-model");
    try expectRequest(try case.runIn(try case.path("work/z"), &keys, &.{ "-p", "hi" }), mocks.c, 1, "/c/v1/chat/completions", "sk-c", "c-model");
    // A preset named at start outranks the directory's.
    try expectRequest(try case.runIn(x, &keys, &.{ "--preset", "b", "-p", "hi" }), mocks.b, 2, "/b/v1/chat/completions", "sk-b", "b-model");

    // Editing preset a is what X uses on its next start; its entry is the
    // same, and so is everything inside the directories.
    const edited = try case.read("state/config.json");
    const pos = std.mem.indexOf(u8, edited, "\"selector\": \"a-model\"") orelse return error.TestUnexpectedResult;
    try case.write("state/config.json", try std.mem.concat(a, u8, &.{ edited[0..pos], "\"selector\": \"b-model\"", edited[pos + "\"selector\": \"a-model\"".len ..] }));
    try expectRequest(try case.runIn(x, &keys, &.{ "-p", "hi" }), mocks.b, 3, "/b/v1/chat/completions", "sk-b", "b-model");
    try testing.expectEqual(@as(usize, 1), mocks.a.requestCount());
    try testing.expectEqualStrings(untouched, try case.listing("work"));
}

test "presets: an unknown preset stops -p before any request and lists the presets (#489)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var mocks = try Mocks.start();
    defer mocks.stop();
    try case.tmp.dir.createDirPath(testing.io, "work/x/.git");
    const x = try case.path("work/x");
    try case.write("state/config.json", try presetConfig(a, &mocks, try std.fmt.allocPrint(a,
        \\, "directory_presets": {{"{s}": "gone"}}{s}
    , .{ x, stored_default_of_c })));
    const config_path = try case.path("state/config.json");
    const listed = try std.fmt.allocPrint(a, "{s} defines no such preset (presets: a, b).", .{config_path});

    const by_flag = try case.run(&keys, &.{ "--preset", "nope", "-p", "hi" });
    try testing.expectEqual(@as(i32, 2), by_flag.exit_code);
    try expectContains(by_flag.stderr, try std.fmt.allocPrint(a, "error: --preset nope: {s}", .{listed}));

    const by_env = try case.run(&(keys ++ [_][]const u8{"METACODES_PRESET=nope"}), &.{ "-p", "hi" });
    try testing.expectEqual(@as(i32, 2), by_env.exit_code);
    try expectContains(by_env.stderr, try std.fmt.allocPrint(a, "error: METACODES_PRESET=nope (in the shell): {s}", .{listed}));

    // Asked for by name, it stops the run even when --provider names the
    // route.
    const beside = try case.run(&keys, &.{ "--preset", "nope", "--provider", "prov-b", "-p", "hi" });
    try testing.expectEqual(@as(i32, 2), beside.exit_code);

    // A directory that remembers a preset config.json no longer defines
    // does not quietly use the /model default (C) instead.
    const remembered = try case.runIn(x, &keys, &.{ "-p", "hi" });
    try testing.expectEqual(@as(i32, 2), remembered.exit_code);
    try expectContains(remembered.stderr, try std.fmt.allocPrint(a, "error: The preset gone remembered for {s}: {s}", .{ x, listed }));
    try testing.expectEqual(@as(usize, 0), mocks.total());

    // A preset named at start sets the directory's aside.
    try expectRequest(try case.runIn(x, &keys, &.{ "--preset", "a", "-p", "hi" }), mocks.a, 1, "/a/v1/chat/completions", "sk-a", "a-model");

    // config.json that cannot be read cannot be looked up: the run says why.
    try case.write("state/config.json", "{\"presets\": {\"a\": \"not a selection\"}}");
    const unreadable = try case.run(&keys, &.{ "--preset", "a", "-p", "hi" });
    try testing.expectEqual(@as(i32, 2), unreadable.exit_code);
    try expectContains(unreadable.stderr, try std.fmt.allocPrint(a, "error: --preset a: {s} cannot be read (InvalidPreset), so no preset can be looked up.", .{config_path}));
    try testing.expectEqual(@as(usize, 1), mocks.total());
}

test "presets: .env's METACODES_PRESET ranks below a /model default and above the file's provider (#489)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var mocks = try Mocks.start();
    defer mocks.stop();

    try case.write("state/.env", "METACODES_PRESET=b\nMETACODES_PROVIDER=prov-a\nPROV_A_TOKEN=sk-a\nPROV_B_TOKEN=sk-b\nPROV_C_TOKEN=sk-c\n");
    try case.write("state/config.json", try presetConfig(a, &mocks, stored_default_of_c));
    try expectRequest(try case.run(&.{}, &.{ "-p", "hi" }), mocks.c, 1, "/c/v1/chat/completions", "sk-c", "c-model");

    try case.write("state/config.json", try presetConfig(a, &mocks, ""));
    try expectRequest(try case.run(&.{}, &.{ "-p", "hi" }), mocks.b, 1, "/b/v1/chat/completions", "sk-b", "b-model");
    try testing.expectEqual(@as(usize, 0), mocks.a.requestCount());

    // An unknown one stops -p once its level is reached, naming the file.
    try case.write("state/.env", "METACODES_PRESET=nope\nPROV_A_TOKEN=sk-a\n");
    const unknown = try case.run(&.{}, &.{ "-p", "hi" });
    try testing.expectEqual(@as(i32, 2), unknown.exit_code);
    try expectContains(unknown.stderr, try std.fmt.allocPrint(a, "error: METACODES_PRESET=nope in {s}: {s} defines no such preset (presets: a, b).", .{
        try case.path("state/.env"), try case.path("state/config.json"),
    }));
    try testing.expectEqual(@as(usize, 2), mocks.total());
}

test "presets: login status shows the preset levels and which one decides (#489)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var mocks = try Mocks.start();
    defer mocks.stop();
    try case.tmp.dir.createDirPath(testing.io, "work/x/.git");
    const x = try case.path("work/x");
    try case.write("state/config.json", try presetConfig(a, &mocks, try std.fmt.allocPrint(a,
        \\, "directory_presets": {{"{s}": "a"}}{s}
    , .{ x, stored_default_of_c })));

    const remembered = try case.runIn(x, &.{"PROV_A_TOKEN=sk-a"}, &.{ "login", "status" });
    try testing.expectEqual(@as(i32, 0), remembered.exit_code);
    const out = remembered.stderr;
    try expectContains(out, try std.fmt.allocPrint(a, "This start uses the preset a, remembered for {s}: Prov A · a-model.\n", .{x}));
    try expectContains(out, "Level 3 of 7 decided; the first that applies wins:\n");
    try expectContains(out, "  2 preset named at start: nothing (METACODES_PRESET is not set)\n");
    try expectContains(out, try std.fmt.allocPrint(a, "> 3 this directory ({s}): remembers a: Prov A · a-model\n", .{x}));
    try expectContains(out, "  4 stored default: not consulted, a preset above decides\n");
    try expectContains(out, "  7 nothing: the TUI opens without a model");
    // The preset's provider's key is its own: not a key that chooses nothing.
    try expectAbsent(out, "Keys in the shell choose no provider");
    try expectAbsent(out, "sk-a");

    const named = try case.runIn(x, &.{"METACODES_PRESET=b"}, &.{ "login", "status" });
    try expectContains(named.stderr, "This start uses the preset b (METACODES_PRESET in the shell): Prov B · b-model.\n");
    try expectContains(named.stderr, "> 2 preset named at start: METACODES_PRESET=b in the shell: Prov B · b-model\n");
    try expectContains(named.stderr, "remembers a: Prov A · a-model (not consulted, a level above decides)\n");

    // Elsewhere, the /model default, while its provider has its key.
    const elsewhere = try case.run(&.{ "METACODES_PRESET=nope", "PROV_C_TOKEN=sk-c" }, &.{ "login", "status" });
    try expectContains(elsewhere.stderr, "Level 4 of 7 decided");
    try expectContains(elsewhere.stderr, "> 4 stored default: Prov C · c-model\n");
    try expectContains(elsewhere.stderr, try std.fmt.allocPrint(a, "  2 preset named at start: METACODES_PRESET=nope in the shell, which {s} does not define (presets: a, b): passed over by the TUI, -p and the rest stop\n", .{try case.path("state/config.json")}));
    try testing.expectEqual(@as(usize, 0), mocks.total());
}

const ANTHROPIC_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const no_global_default =
    \\, "global_default": false
;

fn unchosenError(a: std.mem.Allocator, directory: []const u8, config_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "error: {s} remembers no preset, and {s} sets \"global_default\": false, so nothing is chosen for this directory.\n" ++
        "Name one for this run with --preset <name> (presets: a, b), --provider <id> or --offer <id>, or remember a preset for it under directory_presets.\n", .{ directory, config_path });
}

test "presets: with global_default false, X and Y keep a and b, Z starts on nothing, and none gets a file (#489)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var mocks = try Mocks.start();
    defer mocks.stop();
    var metask = try harness.MockServer.startCassette(&.{ANTHROPIC_SSE}, 0);
    defer metask.stop();
    for ([_][]const u8{ "work/x/.git", "work/y/.git", "work/y/src/deep", "work/z/.git" }) |dir| try case.tmp.dir.createDirPath(testing.io, dir);
    const x = try case.path("work/x");
    const y = try case.path("work/y");
    const z = try case.path("work/z");
    const config_path = try case.path("state/config.json");
    try case.write("state/config.json", try presetConfig(a, &mocks, try std.fmt.allocPrint(a,
        \\, "directory_presets": {{"{s}": "a", "{s}": "b"}}{s}{s}
    , .{ x, y, stored_default_of_c, no_global_default })));
    try case.write("state/.env", "METACODES_PROVIDER=prov-c\nPROV_C_TOKEN=sk-c\n");
    const untouched = try case.listing("work");

    try expectRequest(try case.runIn(x, &keys, &.{ "-p", "hi" }), mocks.a, 1, "/a/v1/chat/completions", "sk-a", "a-model");
    try expectRequest(try case.runIn(try case.path("work/y/src/deep"), &keys, &.{ "-p", "hi" }), mocks.b, 1, "/b/v1/chat/completions", "sk-b", "b-model");

    const metask_url = try metask.urlOwned(a);
    const every_global_level = [_][]const u8{
        keys[0],
        keys[1],
        keys[2],
        keys[3],
        "METASK_API_KEY=mk-never-sent",
        try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{metask_url}),
    };
    const unchosen = try case.runIn(z, &every_global_level, &.{ "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ unchosen.exit_code, unchosen.stderr });
    try testing.expectEqual(@as(i32, 2), unchosen.exit_code);
    try expectContains(unchosen.stderr, try unchosenError(a, z, config_path));
    try testing.expectEqual(@as(usize, 2), mocks.total());
    try testing.expectEqual(@as(usize, 0), metask.requestCount());

    try expectRequest(try case.runIn(z, &keys, &.{ "--preset", "a", "-p", "hi" }), mocks.a, 2, "/a/v1/chat/completions", "sk-a", "a-model");
    try expectRequest(try case.runIn(z, &(keys ++ [_][]const u8{"METACODES_PRESET=b"}), &.{ "-p", "hi" }), mocks.b, 2, "/b/v1/chat/completions", "sk-b", "b-model");
    try expectRequest(try case.runIn(z, &keys, &.{ "--provider", "prov-b", "-p", "hi" }), mocks.b, 3, "/b/v1/chat/completions", "sk-b", "b-model");

    const handed = try case.runIn(z, &keys, &.{ "--api-key", "mk-handed", "--base-url", metask_url, "--model", "claude-sonnet-4-6", "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ handed.exit_code, handed.stderr });
    try testing.expectEqual(@as(i32, 0), handed.exit_code);
    try testing.expectEqual(@as(usize, 1), metask.requestCount());
    try expectContains((metask.lastRequest() orelse return error.NoRequestCaptured).raw, "mk-handed");

    try testing.expectEqual(@as(usize, 0), mocks.c.requestCount());
    try testing.expectEqualStrings(untouched, try case.listing("work"));
}

test "presets: global_default false is read past a malformed preset, and a config.json that is not JSON leaves it off (#489)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var metask = try harness.MockServer.startCassette(&.{ANTHROPIC_SSE}, 0);
    defer metask.stop();
    try case.tmp.dir.createDirPath(testing.io, "work/z/.git");
    const z = try case.path("work/z");
    const config_path = try case.path("state/config.json");
    const signed_in = [_][]const u8{
        "METASK_API_KEY=mk-from-shell",
        try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try metask.urlOwned(a)}),
    };

    try case.write("state/config.json", "{\"presets\": {\"a\": \"not a selection\"}, \"global_default\": false}");
    const malformed = try case.runIn(z, &signed_in, &.{ "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ malformed.exit_code, malformed.stderr });
    try testing.expectEqual(@as(i32, 2), malformed.exit_code);
    try expectContains(malformed.stderr, try std.fmt.allocPrint(a, "error: {s} cannot be read (InvalidPreset), so no preset can be looked up, and it sets \"global_default\": false, so nothing is chosen for this directory.\n" ++
        "Name one for this run with --provider <id> or --offer <id>, or correct {s}.\n", .{ config_path, config_path }));
    try testing.expectEqual(@as(usize, 0), metask.requestCount());

    try case.write("state/config.json", "{\"global_default\": false");
    const not_json = try case.runIn(z, &signed_in, &.{ "--model", "claude-sonnet-4-6", "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ not_json.exit_code, not_json.stderr });
    try testing.expectEqual(@as(i32, 0), not_json.exit_code);
    try expectContains(not_json.stderr, "config.json could not be read");
    try testing.expectEqual(@as(usize, 1), metask.requestCount());
    try expectContains((metask.lastRequest() orelse return error.NoRequestCaptured).raw, "mk-from-shell");
}

test "presets: login status says global_default is false and which levels it leaves out (#489)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var mocks = try Mocks.start();
    defer mocks.stop();
    for ([_][]const u8{ "work/x/.git", "work/z/.git" }) |dir| try case.tmp.dir.createDirPath(testing.io, dir);
    const x = try case.path("work/x");
    const z = try case.path("work/z");
    const config_path = try case.path("state/config.json");
    try case.write("state/config.json", try presetConfig(a, &mocks, try std.fmt.allocPrint(a,
        \\, "directory_presets": {{"{s}": "a"}}{s}{s}
    , .{ x, stored_default_of_c, no_global_default })));
    try case.write("state/.env", "METACODES_PROVIDER=prov-c\nPROV_C_TOKEN=sk-c\n");
    const mode_line = try std.fmt.allocPrint(a, "global_default is false in {s}: levels 4 to 6 choose for no directory.\n", .{config_path});

    const in_z = try case.runIn(z, &.{"METASK_API_KEY=mk-never-sent"}, &.{ "login", "status" });
    try testing.expectEqual(@as(i32, 0), in_z.exit_code);
    const out = in_z.stderr;
    try expectContains(out, try std.fmt.allocPrint(a, "This start uses no provider: {s} remembers no preset, and global_default is false.\n", .{z}));
    try expectContains(out, mode_line);
    try expectContains(out, "Level 7 of 7 decided; the first that applies wins:\n");
    try expectContains(out, try std.fmt.allocPrint(a, "  3 this directory ({s}): remembers no preset\n", .{z}));
    try expectContains(out, "  4 stored default: not consulted, global_default is false\n");
    try expectContains(out, "      METASK_API_KEY: set in the shell\n      not consulted: global_default is false\n");
    try expectContains(out, "; configures Prov C\n      not consulted: global_default is false\n");
    try expectContains(out, "> 7 nothing: the TUI opens without a model; -p and the rest stop\n");
    try expectAbsent(out, "mk-never-sent");

    const in_x = try case.runIn(x, &.{"PROV_A_TOKEN=sk-a"}, &.{ "login", "status" });
    try expectContains(in_x.stderr, try std.fmt.allocPrint(a, "This start uses the preset a, remembered for {s}: Prov A · a-model.\n", .{x}));
    try expectContains(in_x.stderr, mode_line);
    try expectContains(in_x.stderr, "Level 3 of 7 decided");
    try testing.expectEqual(@as(usize, 0), mocks.total());
}

test "presets: a Metask key in .env waits while the same file's preset is not on Metask (#748)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    var mocks = try Mocks.start();
    defer mocks.stop();
    const env_path = try case.path("state/.env");
    const config_path = try case.path("state/config.json");
    const every_route_at_b = try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}/b/v1", .{try originOf(a, mocks.b)});

    try case.write("state/config.json", try presetConfig(a, &mocks, ""));
    try case.write("state/.env", "METACODES_PRESET=b\nPROV_B_TOKEN=sk-b\nMETASK_API_KEY=mk-file-key\n");
    const status = try case.run(&.{}, &.{ "login", "status" });
    try expectContains(status.stderr, try std.fmt.allocPrint(a, "This start uses the preset b from {s}: Prov B · b-model.\n", .{env_path}));
    try expectContains(status.stderr, "Level 6 of 7 decided");
    try expectContains(status.stderr, try std.fmt.allocPrint(a, "      METASK_API_KEY: set in {s}, for when Metask is chosen (the file's preset b is not on Metask)\n", .{env_path}));
    try expectAbsent(status.stderr, "mk-file-key");
    try expectRequest(try case.run(&.{ every_route_at_b, "METACODES_LOG=openai:info" }, &.{ "-p", "hi" }), mocks.b, 1, "/b/v1/chat/completions", "sk-b", "b-model");

    try case.write("state/.env", "METACODES_PRESET=nope\nMETASK_API_KEY=mk-file-key\n");
    const unknown = try case.run(&.{every_route_at_b}, &.{ "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ unknown.exit_code, unknown.stderr });
    try testing.expectEqual(@as(i32, 2), unknown.exit_code);
    try expectContains(unknown.stderr, try std.fmt.allocPrint(a, "error: METACODES_PRESET=nope in {s}: {s} defines no such preset (presets: a, b).", .{ env_path, config_path }));
    try testing.expectEqual(@as(usize, 1), mocks.total());

    try case.write("state/config.json", "{\"presets\": {\"m\": {\"target\": {\"kind\": \"auto_route\", \"selector\": \"claude-sonnet-4-6\"}}}}");
    try case.write("state/.env", "METACODES_PRESET=m\nMETASK_API_KEY=mk-file-key\n");
    const on_metask = try case.run(&.{}, &.{ "login", "status" });
    try expectContains(on_metask.stderr, "This start uses Metask with METASK_API_KEY from .env.\n");
    try expectContains(on_metask.stderr, "Level 5 of 7 decided");
    try expectContains(on_metask.stderr, try std.fmt.allocPrint(a, "      METASK_API_KEY: set in {s}\n", .{env_path}));
}
