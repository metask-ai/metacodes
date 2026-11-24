const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const golden = @import("golden.zig");
const normalize = @import("normalize.zig");
const abi = @import("abi.zig");

const testing = std.testing;
const io = testing.io;

const Env = struct {
    contract_root: []const u8,
    cli: []const u8,
    mock_mcp: []const u8,
    agentcore_header: []const u8,
    agentcore_shared: []const u8,
    version: []const u8,
    mode: golden.Mode,

    fn load() !Env {
        return .{
            .contract_root = try required("METACODES_CONTRACT_ROOT"),
            .cli = try required("METACODES_TEST_CLI_BIN"),
            .mock_mcp = try required("METACODES_CONTRACT_MOCK_MCP"),
            .agentcore_header = try required("METACODES_CONTRACT_AGENTCORE_HEADER"),
            .agentcore_shared = try required("METACODES_CONTRACT_AGENTCORE_SHARED"),
            .version = try required("METACODES_CONTRACT_VERSION"),
            .mode = if (std.c.getenv("METACODES_CONTRACT_UPDATE")) |raw|
                if (std.mem.eql(u8, std.mem.span(raw), "1")) .update else .check
            else
                .check,
        };
    }

    fn required(name: [:0]const u8) ![]const u8 {
        const raw = std.c.getenv(name) orelse {
            std.debug.print("{s} is not set; run the suite through zig build test:contract\n", .{name});
            return error.MissingContractEnvironment;
        };
        return std.mem.span(raw);
    }

    fn store(env: Env) golden.Store {
        return .{ .io = io, .root = env.contract_root, .mode = env.mode };
    }
};

const Checker = struct {
    store: golden.Store,
    failures: usize = 0,

    fn expect(checker: *Checker, a: std.mem.Allocator, rel_path: []const u8, actual: []const u8) !void {
        checker.store.expect(a, rel_path, actual) catch |err| switch (err) {
            error.ContractDrift, error.ContractSnapshotMissing => checker.failures += 1,
            else => return err,
        };
    }

    fn finish(checker: Checker) !void {
        if (checker.failures > 0) return error.ContractDrift;
    }
};

test "AgentCore C ABI: header declarations, struct layouts and constants" {
    const env = try Env.load();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const header = try std.Io.Dir.cwd().readFileAlloc(io, env.agentcore_header, a, .limited(16 << 20));
    try env.store().expect(a, "abi/agentcore_h.txt", try abi.layout(a, header));
}

test "AgentCore C ABI: symbols the shared library exports" {
    const env = try Env.load();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, env.agentcore_shared, a, .limited(1 << 30));
    try env.store().expect(a, "abi/exports.txt", try abi.exports(a, bytes));
}

const Scratch = struct {
    arena_state: std.heap.ArenaAllocator,
    root: []const u8,
    spelled_root: []const u8,
    home: []const u8,
    state: []const u8,
    work: []const u8,
    today_before: [2]normalize.Literal,

    var counter: std.atomic.Value(u32) = .init(0);

    fn init(self: *Scratch) !void {
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena_state.deinit();
        const a = self.arena_state.allocator();
        self.spelled_root = try std.fmt.allocPrint(a, "/tmp/metacodes-contract-{d}-{d}", .{ std.c.getpid(), counter.fetchAdd(1, .monotonic) });
        std.Io.Dir.cwd().deleteTree(io, self.spelled_root) catch {};
        for ([_][]const u8{ "home", "state", "work" }) |sub| {
            try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ self.spelled_root, sub }));
        }
        self.root = try std.Io.Dir.cwd().realPathFileAlloc(io, self.spelled_root, a);
        self.home = try std.fs.path.join(a, &.{ self.root, "home" });
        self.state = try std.fs.path.join(a, &.{ self.root, "state" });
        self.work = try std.fs.path.join(a, &.{ self.root, "work" });
        self.today_before = try todayLiterals(a);
    }

    fn deinit(self: *Scratch) void {
        std.Io.Dir.cwd().deleteTree(io, self.spelled_root) catch {};
        self.arena_state.deinit();
    }

    fn arena(self: *Scratch) std.mem.Allocator {
        return self.arena_state.allocator();
    }
};

const Run = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
};

fn runCli(scratch: *Scratch, env: Env, extra_env: []const []const u8, args: []const []const u8) !Run {
    const a = scratch.arena();
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    const base = [_][]const u8{
        "/usr/bin/env",
        "-i",
        try std.fmt.allocPrint(a, "HOME={s}", .{scratch.home}),
        "PATH=/usr/bin:/bin",
        "TZ=UTC",
        "LANG=C",
        "METACODES_KG_AUTOSTART=0",
        "METACODES_JEV_URL=off",
        "METACODES_NO_PROBE=1",
        "METACODES_NO_UPDATE_CHECK=1",
    };
    for (base) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    for (extra_env) |assignment| try argv.append(a, (try a.dupeZ(u8, assignment)).ptr);
    try argv.append(a, (try a.dupeZ(u8, env.cli)).ptr);
    for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    try argv.append(a, null);
    const out = try cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 120_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, scratch.work);
    return .{ .exit_code = out.exit_code, .stdout = out.stdout, .stderr = out.stderr };
}

const weekdays = [_][]const u8{ "Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday" };

fn todayLiterals(a: std.mem.Allocator) ![2]normalize.Literal {
    const seconds = std.Io.Clock.real.now(io).toSeconds();
    const day = (std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) }).getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const date = try std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 });
    return .{
        .{ .needle = try std.fmt.allocPrint(a, "{s} ({s})", .{ date, weekdays[day.day % 7] }), .placeholder = "<DATE>" },
        .{ .needle = date, .placeholder = "<DATE>" },
    };
}

fn literals(scratch: *Scratch, env: Env, extra: []const normalize.Literal) ![]const normalize.Literal {
    const a = scratch.arena();
    var list: std.ArrayList(normalize.Literal) = .empty;
    try list.appendSlice(a, &scratch.today_before);
    try list.appendSlice(a, &try todayLiterals(a));
    try list.appendSlice(a, &.{
        .{ .needle = scratch.root, .placeholder = "<ROOT>" },
        .{ .needle = scratch.spelled_root, .placeholder = "<ROOT>" },
        .{ .needle = env.cli, .placeholder = "<CLI>" },
        .{ .needle = env.mock_mcp, .placeholder = "<MOCK_MCP>" },
        .{ .needle = env.version, .placeholder = "<VERSION>" },
    });
    try list.appendSlice(a, extra);
    return list.items;
}

const CliCase = struct {
    name: []const u8,
    args: []const []const u8,
};

const cli_cases = [_]CliCase{
    .{ .name = "help", .args = &.{"--help"} },
    .{ .name = "login-help", .args = &.{ "login", "--help" } },
    .{ .name = "doctor-help", .args = &.{ "doctor", "--help" } },
    .{ .name = "install-help", .args = &.{ "install", "--help" } },
    .{ .name = "sealed-help", .args = &.{ "sealed", "--help" } },
    .{ .name = "mcp-help", .args = &.{ "mcp", "--help" } },
    .{ .name = "providers-help", .args = &.{ "providers", "--help" } },
    .{ .name = "teamwork-help", .args = &.{ "teamwork", "--help" } },
    .{ .name = "terminal-setup-help", .args = &.{ "terminal-setup", "--help" } },
    .{ .name = "update-help", .args = &.{ "update", "--help" } },
    .{ .name = "error-unknown-flag", .args = &.{"--no-such-flag"} },
    .{ .name = "error-missing-value", .args = &.{"--model"} },
    .{ .name = "error-bad-permission", .args = &.{ "--permission", "sometimes", "-p", "x" } },
    .{ .name = "error-resume-with-print", .args = &.{ "--resume", "abc", "-p", "x" } },
    .{ .name = "error-no-credentials", .args = &.{ "-p", "x" } },
    .{ .name = "check-providers-empty", .args = &.{"--check-providers"} },
};

test "CLI: help text and the exit codes of the main error paths" {
    const env = try Env.load();
    var checker: Checker = .{ .store = env.store() };
    for (cli_cases) |case| {
        var scratch: Scratch = undefined;
        try scratch.init();
        defer scratch.deinit();
        const a = scratch.arena();
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ "--state-dir", scratch.state });
        try args.appendSlice(a, case.args);
        const run = try runCli(&scratch, env, &.{}, args.items);
        var text: std.ArrayList(u8) = .empty;
        try text.print(a, "$ metacodes", .{});
        for (args.items) |arg| try text.print(a, " {s}", .{arg});
        try text.print(a, "\nexit: {d}\n--- stdout\n{s}--- stderr\n{s}", .{ run.exit_code, run.stdout, run.stderr });
        const normalized = try normalize.apply(a, text.items, .{ .literals = try literals(&scratch, env, &.{}) });
        try checker.expect(a, try std.fmt.allocPrint(a, "cli/{s}.txt", .{case.name}), normalized);
    }
    try checker.finish();
}

const Scenario = struct {
    name: []const u8,
    args: []const []const u8,
    env: []const []const u8 = &.{},
};

const scenarios = [_]Scenario{
    .{ .name = "single_turn", .args = &.{ "-p", "say hi" } },
    .{ .name = "tool_multi_turn", .args = &.{ "--permission", "acceptEdits", "-p", "copy the note" } },
    .{ .name = "parallel_tools", .args = &.{ "-p", "read both files" } },
    .{ .name = "permission_denied", .args = &.{ "--disallowedTools", "Bash", "-p", "write and list" } },
    .{ .name = "subagent", .args = &.{ "-p", "delegate the search" } },
    .{ .name = "mcp_tool", .args = &.{ "--allowedTools", "mcp__mock__echo", "-p", "echo ping" } },
    .{ .name = "skill_activation", .args = &.{ "-p", "greet me" } },
    .{ .name = "compaction", .args = &.{ "-p", "read the notes" }, .env = &.{ "METACODES_FORCE_COMPACT_AT=20000", "METACODES_FORCE_COMPACT_KEEP=1" } },
};

test "provider request bytes, stream-json events and session files of fixed scenarios" {
    const env = try Env.load();
    var checker: Checker = .{ .store = env.store() };
    for (scenarios) |scenario| {
        runScenario(env, &checker, scenario) catch |err| {
            std.debug.print("scenario {s} failed: {s}\n", .{ scenario.name, @errorName(err) });
            return err;
        };
    }
    try checker.finish();
}

fn runScenario(env: Env, checker: *Checker, scenario: Scenario) !void {
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    const a = scratch.arena();
    const dir = try std.fs.path.join(a, &.{ env.contract_root, "scenarios", scenario.name });
    const substitutions = [_]normalize.Literal{.{ .needle = "<MOCK_MCP>", .placeholder = env.mock_mcp }};
    try copyTree(a, try std.fs.path.join(a, &.{ dir, "work" }), scratch.work, &.{});
    try copyTree(a, try std.fs.path.join(a, &.{ dir, "state" }), scratch.state, &substitutions);
    const bodies = try loadCassette(a, dir);
    const server = try harness.MockServer.startCassette(bodies, 0);
    defer server.stop();
    const base_url = try server.urlOwned(a);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "--state-dir", scratch.state, "--api-key", "sk-contract", "--base-url", base_url, "--json", "--stream-json" });
    try args.appendSlice(a, scenario.args);
    const run = try runCli(&scratch, env, scenario.env, args.items);

    const provider = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{server.port});
    const rules: normalize.Rules = .{ .literals = try literals(&scratch, env, &.{.{ .needle = provider, .placeholder = "<PROVIDER>" }}) };
    const expected_dir = try std.fmt.allocPrint(a, "scenarios/{s}/expected", .{scenario.name});
    if (env.mode == .update) try std.Io.Dir.cwd().deleteTree(io, try std.fs.path.join(a, &.{ env.contract_root, expected_dir }));

    var process: std.ArrayList(u8) = .empty;
    try process.print(a, "exit: {d}\nrequests: {d}\n--- stderr\n{s}", .{ run.exit_code, server.requestCount(), run.stderr });
    try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, "process.txt" }), try normalize.apply(a, process.items, rules));
    try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, "stream.jsonl" }), try normalize.apply(a, run.stdout, rules));

    for (0..server.requestCount()) |index| {
        const request = server.requestAt(index).?;
        const text = try renderRequest(a, request.raw);
        const name = try std.fmt.allocPrint(a, "request-{d:0>3}.txt", .{index + 1});
        try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, name }), try normalize.apply(a, text, rules));
    }

    const sessions = try sessionDirs(a, scratch.state);
    for (sessions, 0..) |session, index| {
        for ([_][]const u8{ "transcript.jsonl", "meta.json" }) |file| {
            const path = try std.fs.path.join(a, &.{ session, file });
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            const name = try std.fmt.allocPrint(a, "session-{d}/{s}", .{ index + 1, file });
            try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, name }), try normalize.apply(a, bytes, rules));
        }
    }
    try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, "state-files.txt" }), try normalize.apply(a, try listTree(a, scratch.state), rules));
}

fn loadCassette(a: std.mem.Allocator, dir: []const u8) ![]const []const u8 {
    var bodies: std.ArrayList([]const u8) = .empty;
    var index: usize = 1;
    while (true) : (index += 1) {
        const path = try std.fmt.allocPrint(a, "{s}/sse-{d:0>3}.txt", .{ dir, index });
        const body = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20)) catch |err| switch (err) {
            error.FileNotFound => break,
            else => return err,
        };
        try bodies.append(a, body);
    }
    if (bodies.items.len == 0) return error.EmptyCassette;
    return bodies.items;
}

fn renderRequest(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const split = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.MalformedRequest;
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitSequence(u8, raw[0..split], "\r\n");
    var chunked = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            try out.print(a, "{s}\n", .{line});
            continue;
        };
        const name = line[0..colon];
        if (std.ascii.eqlIgnoreCase(name, "host") or std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            chunked = std.mem.indexOf(u8, line, "chunked") != null;
            continue;
        }
        try out.print(a, "{s}\n", .{line});
    }
    try out.append(a, '\n');
    const body = raw[split + 4 ..];
    try out.appendSlice(a, try normalize.splitJson(a, if (chunked) try dechunk(a, body) else body));
    return out.items;
}

fn dechunk(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = body;
    while (true) {
        const eol = std.mem.indexOf(u8, rest, "\r\n") orelse return error.MalformedChunk;
        const size = try std.fmt.parseInt(usize, rest[0..eol], 16);
        rest = rest[eol + 2 ..];
        if (size == 0) break;
        if (rest.len < size + 2) return error.MalformedChunk;
        try out.appendSlice(a, rest[0..size]);
        rest = rest[size + 2 ..];
    }
    return out.items;
}

fn sessionDirs(a: std.mem.Allocator, state: []const u8) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    const projects = try std.fs.path.join(a, &.{ state, "projects" });
    var projects_dir = std.Io.Dir.cwd().openDir(io, projects, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return found.items,
        else => return err,
    };
    defer projects_dir.close(io);
    var walker = try projects_dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "transcript.jsonl")) continue;
        try found.append(a, try std.fs.path.join(a, &.{ projects, std.fs.path.dirname(entry.path).? }));
    }
    std.mem.sort([]const u8, found.items, {}, lessThan);
    return found.items;
}

fn listTree(a: std.mem.Allocator, root: []const u8) ![]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
        try paths.append(a, try std.fmt.allocPrint(a, "{s}{s}", .{ entry.path, suffix }));
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    var out: std.ArrayList(u8) = .empty;
    for (paths.items) |path| try out.print(a, "{s}\n", .{path});
    return out.items;
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn copyTree(a: std.mem.Allocator, from: []const u8, to: []const u8, substitutions: []const normalize.Literal) !void {
    var dir = std.Io.Dir.cwd().openDir(io, from, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const target = try std.fs.path.join(a, &.{ to, entry.path });
        switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(io, target),
            .file => {
                var bytes = try entry.dir.readFileAlloc(io, entry.basename, a, .limited(16 << 20));
                for (substitutions) |rule| bytes = try std.mem.replaceOwned(u8, a, bytes, rule.needle, rule.placeholder);
                if (std.fs.path.dirname(target)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = bytes });
            },
            else => return error.UnsupportedFixtureEntry,
        }
    }
}

test "on-disk session written by an earlier build reads back the same" {
    const env = try Env.load();
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    const a = scratch.arena();
    const fixture = try std.fs.path.join(a, &.{ env.contract_root, "state_fixture" });
    const cwd_hash = cc.transcript.hashCwd(scratch.work);
    const project = try std.fs.path.join(a, &.{ scratch.state, "projects", &cwd_hash });
    try copyTree(a, try std.fs.path.join(a, &.{ fixture, "projects", "PROJECT" }), project, &.{});

    var out: std.ArrayList(u8) = .empty;
    const sessions = try cc.transcript.listSessions(scratch.work, .{ .path = scratch.state }, a);
    std.mem.sort(cc.transcript.SessionListEntry, sessions, {}, struct {
        fn lt(_: void, lhs: cc.transcript.SessionListEntry, rhs: cc.transcript.SessionListEntry) bool {
            return std.mem.lessThan(u8, lhs.id, rhs.id);
        }
    }.lt);
    for (sessions) |entry| {
        try out.print(a, "session {s}\ntitle: {s}\nmodel: {s}\nmessages: {d}\n", .{ entry.id, entry.title, entry.model, entry.message_count });
        var conversation = cc.conversation.Conversation.init(testing.allocator);
        defer conversation.deinit();
        try cc.transcript.loadTranscript(&conversation, entry.path, testing.allocator);
        try out.print(a, "compact_boundary: {d}\ncompact_summary: {s}\n", .{ conversation.compact_boundary, conversation.compact_summary orelse "null" });
        for (conversation.messages.items) |*message| {
            var aw: std.Io.Writer.Allocating = .init(a);
            try cc.transcript.Writer.renderMessageJson(&aw.writer, message);
            try out.print(a, "{s}\n", .{aw.written()});
        }
    }
    try env.store().expect(a, "state_fixture/read-back.txt", out.items);
}
