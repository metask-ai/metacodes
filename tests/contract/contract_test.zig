const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const golden = @import("golden.zig");
const normalize = @import("normalize.zig");
const abi = @import("abi.zig");
const sse = @import("sse.zig");

const testing = std.testing;
const io = testing.io;

const Env = struct {
    contract_root: []const u8,
    cli: []const u8,
    mock_mcp: []const u8,
    agentcore_header: []const u8,
    agentcore_shared: []const u8,
    c_consumer: []const u8,
    version: []const u8,
    tinykg: []const u8,
    tinykgd: []const u8,
    mode: golden.Mode,

    fn load() !Env {
        return .{
            .contract_root = try required("METACODES_CONTRACT_ROOT"),
            .cli = try required("METACODES_TEST_CLI_BIN"),
            .mock_mcp = try required("METACODES_CONTRACT_MOCK_MCP"),
            .agentcore_header = try required("METACODES_CONTRACT_AGENTCORE_HEADER"),
            .agentcore_shared = try required("METACODES_CONTRACT_AGENTCORE_SHARED"),
            .c_consumer = try required("METACODES_CONTRACT_C_CONSUMER"),
            .version = try required("METACODES_CONTRACT_VERSION"),
            .tinykg = try required("METACODES_TEST_TINYKG_BIN"),
            .tinykgd = try required("METACODES_TEST_TINYKGD_BIN"),
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

test "AgentCore C ABI: a C consumer built from the shipped header alone runs against the shared library" {
    const env = try Env.load();
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    const a = scratch.arena();
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    for ([_][]const u8{ env.c_consumer, env.agentcore_shared }) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    try argv.append(a, null);
    const out = try cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 120_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, scratch.work);
    var text: std.ArrayList(u8) = .empty;
    try text.print(a, "$ agentcore-contract-c-consumer <AGENTCORE_SHARED>\nexit: {d}\n--- stdout\n{s}--- stderr\n{s}", .{ out.exit_code, out.stdout, out.stderr });
    const rules: normalize.Rules = .{ .literals = try literals(&scratch, env, &.{.{ .needle = env.agentcore_shared, .placeholder = "<AGENTCORE_SHARED>" }}) };
    try env.store().expect(a, "abi/c_consumer.txt", try normalize.apply(a, text.items, rules));
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

fn cliArgv(scratch: *Scratch, env: Env, extra_env: []const []const u8, args: []const []const u8) ![]const []const u8 {
    const a = scratch.arena();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{
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
    });
    try argv.appendSlice(a, extra_env);
    try argv.append(a, env.cli);
    try argv.appendSlice(a, args);
    return argv.items;
}

fn runCli(scratch: *Scratch, env: Env, extra_env: []const []const u8, args: []const []const u8) !Run {
    const a = scratch.arena();
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    for (try cliArgv(scratch, env, extra_env, args)) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    try argv.append(a, null);
    const out = try cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 120_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, scratch.work);
    return .{ .exit_code = out.exit_code, .stdout = out.stdout, .stderr = out.stderr };
}

const interrupt_deadline_ms = 60_000;
const interrupted_exit_limit_ms = 3_000;

fn runCliInterrupted(scratch: *Scratch, env: Env, server: *harness.MockServer, extra_env: []const []const u8, args: []const []const u8, interrupt: Interrupt) !Run {
    const a = scratch.arena();
    const stdout_path = try std.fs.path.join(a, &.{ scratch.root, "stdout" });
    const stderr_path = try std.fs.path.join(a, &.{ scratch.root, "stderr" });
    const exit_code = exit: {
        const stdout_file = try std.Io.Dir.cwd().createFile(io, stdout_path, .{});
        defer stdout_file.close(io);
        const stderr_file = try std.Io.Dir.cwd().createFile(io, stderr_path, .{});
        defer stderr_file.close(io);
        var child = try std.process.spawn(io, .{
            .argv = try cliArgv(scratch, env, extra_env, args),
            .cwd = .{ .path = scratch.work },
            .stdin = .ignore,
            .stdout = .{ .file = stdout_file },
            .stderr = .{ .file = stderr_file },
        });
        errdefer child.kill(io);
        try waitForInterruptPoint(scratch, server, stdout_path, interrupt);
        const interrupted_at = cc.util_time.nowMs();
        try std.posix.kill(child.id.?, .INT);
        const term = try child.wait(io);
        const exit_ms = cc.util_time.nowMs() - interrupted_at;
        if (exit_ms > interrupted_exit_limit_ms) {
            std.debug.print("the CLI took {d}ms to exit after SIGINT (limit {d}ms)\n", .{ exit_ms, interrupted_exit_limit_ms });
            return error.InterruptTooSlow;
        }
        break :exit switch (term) {
            .exited => |code| @as(i32, code),
            .signal => |signal| 128 + @as(i32, @intCast(@intFromEnum(signal))),
            else => return error.ChildStoppedUnexpectedly,
        };
    };
    return .{
        .exit_code = exit_code,
        .stdout = try std.Io.Dir.cwd().readFileAlloc(io, stdout_path, a, .limited(64 << 20)),
        .stderr = try std.Io.Dir.cwd().readFileAlloc(io, stderr_path, a, .limited(64 << 20)),
    };
}

fn waitForInterruptPoint(scratch: *Scratch, server: *harness.MockServer, stdout_path: []const u8, interrupt: Interrupt) !void {
    const a = scratch.arena();
    const deadline = cc.util_time.nowMs() + interrupt_deadline_ms;
    while (cc.util_time.nowMs() < deadline) : (cc.util_time.sleepMs(20)) {
        switch (interrupt) {
            .none => return,
            .after_request => if (server.requestCount() > 0) return,
            .after_output => |needle| {
                const stdout = try std.Io.Dir.cwd().readFileAlloc(io, stdout_path, a, .limited(64 << 20));
                if (std.mem.indexOf(u8, stdout, needle) != null) return;
            },
            .after_file => |name| {
                const path = try std.fs.path.join(a, &.{ scratch.work, name });
                if (std.Io.Dir.cwd().access(io, path, .{})) |_| return else |_| {}
            },
        }
    }
    std.debug.print("the run never reached its interrupt point {any}\n", .{interrupt});
    return error.InterruptPointNeverReached;
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

fn environmentLiterals(a: std.mem.Allocator) ![2]normalize.Literal {
    var uts: std.c.utsname = undefined;
    if (std.c.uname(&uts) != 0) return error.UnameFailed;
    const sysname = std.mem.sliceTo(&uts.sysname, 0);
    const release = std.mem.sliceTo(&uts.release, 0);
    return .{
        .{ .needle = try std.fmt.allocPrint(a, "Platform: {s}", .{try std.ascii.allocLowerString(a, sysname)}), .placeholder = "Platform: <PLATFORM>" },
        .{ .needle = try std.fmt.allocPrint(a, "OS Version: {s} {s}", .{ sysname, release }), .placeholder = "OS Version: <OS_VERSION>" },
    };
}

fn literals(scratch: *Scratch, env: Env, extra: []const normalize.Literal) ![]const normalize.Literal {
    const a = scratch.arena();
    var list: std.ArrayList(normalize.Literal) = .empty;
    try list.appendSlice(a, &scratch.today_before);
    try list.appendSlice(a, &try todayLiterals(a));
    try list.appendSlice(a, &try environmentLiterals(a));
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

const Provider = union(enum) {
    cassette,
    status_lines: []const []const u8,
    cut_response: usize,
    event_interval_ms: u32,
    silent_head,
    silent_after: []const u8,
};

const Interrupt = union(enum) {
    none,
    after_request,
    after_output: []const u8,
    after_file: []const u8,
};

const Scenario = struct {
    name: []const u8,
    args: []const []const u8,
    env: []const []const u8 = &.{},
    provider: Provider = .cassette,
    interrupt: Interrupt = .none,
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
    .{ .name = "provider_4xx", .args = &.{ "-p", "say hi" }, .provider = .{ .status_lines = &.{"HTTP/1.1 400 Bad Request"} } },
    .{ .name = "provider_5xx_retry", .args = &.{ "-p", "say hi" }, .provider = .{ .status_lines = &.{ "HTTP/1.1 500 Internal Server Error", "HTTP/1.1 503 Service Unavailable", "HTTP/1.1 200 OK" } } },
    .{ .name = "provider_529", .args = &.{ "-p", "say hi" }, .provider = .{ .status_lines = &.{"HTTP/1.1 529 Overloaded"} } },
    .{ .name = "sse_cut", .args = &.{ "-p", "say hi" }, .provider = .{ .cut_response = 0 } },
    .{ .name = "user_interrupt", .args = &.{ "-p", "say hi" }, .provider = .{ .event_interval_ms = 1000 }, .interrupt = .{ .after_output = "\"type\":\"usage\"" } },
    .{ .name = "tool_abort", .args = &.{ "--allowedTools", "Bash", "-p", "run the slow check" }, .interrupt = .{ .after_file = "started" } },
    .{ .name = "interrupt_awaiting_head", .args = &.{ "-p", "say hi" }, .provider = .silent_head, .interrupt = .after_request },
    .{ .name = "interrupt_stalled_stream", .args = &.{ "-p", "say hi" }, .provider = .{ .silent_after = "\"text\":\"Hello\"}}\n\n" }, .interrupt = .{ .after_output = "\"type\":\"text\"" } },
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
    const server = switch (scenario.provider) {
        .cassette => try harness.MockServer.startCassette(bodies, 0),
        .status_lines => |lines| try harness.MockServer.startHttpCassette(bodies, lines),
        .cut_response => |index| try harness.MockServer.startCassetteMidStreamCut(bodies, index),
        .event_interval_ms => |interval| try harness.MockServer.startCassette(bodies, interval),
        .silent_head => try harness.MockServer.startCassetteSilent(bodies, 0, 0),
        .silent_after => |marker| try harness.MockServer.startCassetteSilent(bodies, 0, try prefixThrough(bodies[0], marker)),
    };
    defer server.stop();
    const base_url = try server.urlOwned(a);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "--state-dir", scratch.state, "--api-key", "sk-contract", "--base-url", base_url, "--json", "--stream-json" });
    try args.appendSlice(a, scenario.args);
    const run = switch (scenario.interrupt) {
        .none => try runCli(&scratch, env, scenario.env, args.items),
        else => try runCliInterrupted(&scratch, env, server, scenario.env, args.items, scenario.interrupt),
    };

    const provider = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{server.port});
    const rules: normalize.Rules = .{ .literals = try literals(&scratch, env, &.{.{ .needle = provider, .placeholder = "<PROVIDER>" }}) };
    const expected_dir = try std.fmt.allocPrint(a, "scenarios/{s}/expected", .{scenario.name});
    if (env.mode == .update) try std.Io.Dir.cwd().deleteTree(io, try std.fs.path.join(a, &.{ env.contract_root, expected_dir }));

    var process: std.ArrayList(u8) = .empty;
    try process.print(a, "exit: {d}\nrequests: {d}\n--- stderr\n{s}", .{ run.exit_code, server.requestCount(), run.stderr });
    try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, "process.txt" }), try normalize.apply(a, process.items, rules));
    try checkStream(checker, a, expected_dir, run.stdout, rules);

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

fn prefixThrough(body: []const u8, marker: []const u8) !usize {
    const start = std.mem.indexOf(u8, body, marker) orelse return error.SilenceMarkerMissing;
    return start + marker.len;
}

fn checkStream(checker: *Checker, a: std.mem.Allocator, expected_dir: []const u8, stream: []const u8, rules: normalize.Rules) !void {
    if (!try toolResultSizesMatch(a, stream)) {
        std.debug.print("{s}: a tool_result's content_bytes differs from its content\n", .{expected_dir});
        checker.failures += 1;
    }
    try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, "stream.jsonl" }), try normalize.apply(a, stream, rules));
}

fn toolResultSizesMatch(a: std.mem.Allocator, stream: []const u8) !bool {
    var all_match = true;
    var lines = std.mem.tokenizeScalar(u8, stream, '\n');
    while (lines.next()) |line| {
        const event = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        if (event != .object) continue;
        const kind = event.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "tool_result")) continue;
        const content = event.object.get("content") orelse continue;
        const size = event.object.get("content_bytes") orelse continue;
        if (content != .string or size != .integer) continue;
        if (event.object.get("truncated")) |truncated| if (truncated == .bool and truncated.bool) continue;
        if (size.integer != content.string.len) {
            std.debug.print("content_bytes {d}, content {d} bytes: {s}\n", .{ size.integer, content.string.len, line });
            all_match = false;
        }
    }
    return all_match;
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

const pnet = @import("platform").net;

fn spawnCli(scratch: *Scratch, env: Env, args: []const []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = try cliArgv(scratch, env, &.{}, args),
        .cwd = .{ .path = scratch.work },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

const connect_deadline_ms = 20_000;
const stream_deadline_ms = 60_000;

fn connectWhenReady(comptime connectFn: anytype, target: anytype) !pnet.Socket {
    const deadline = cc.util_time.nowMs() + connect_deadline_ms;
    while (true) {
        if (connectFn(target)) |conn| return conn else |_| {}
        if (cc.util_time.nowMs() >= deadline) return error.DaemonNeverListened;
        cc.util_time.sleepMs(50);
    }
}

fn sendAll(conn: pnet.Socket, bytes: []const u8) !void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = pnet.send(conn, bytes[pos..]);
        if (n <= 0) return error.WriteFailed;
        pos += @intCast(n);
    }
}

fn readUntil(a: std.mem.Allocator, conn: pnet.Socket, needle: []const u8) ![]const u8 {
    return readThrough(a, conn, needle, "\n");
}

fn readThrough(a: std.mem.Allocator, conn: pnet.Socket, needle: []const u8, terminator: []const u8) ![]const u8 {
    pnet.setRecvTimeoutMs(conn, 200);
    const deadline = cc.util_time.nowMs() + stream_deadline_ms;
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        if (std.mem.indexOf(u8, out.items, needle)) |at| {
            if (std.mem.indexOfPos(u8, out.items, at, terminator)) |end| return out.items[0 .. end + terminator.len];
        }
        if (cc.util_time.nowMs() >= deadline) {
            std.debug.print("stream never showed {s}; got:\n{s}\n", .{ needle, out.items });
            return error.StreamTimeout;
        }
        const n = pnet.recv(conn, &chunk);
        if (n == 0) {
            std.debug.print("stream closed before {s} and its terminator; got:\n{s}\n", .{ needle, out.items });
            return error.StreamClosed;
        }
        if (n < 0) {
            if (pnet.recvRetriable()) continue;
            return error.StreamFailed;
        }
        try out.appendSlice(a, chunk[0..@intCast(n)]);
    }
}

fn udsRequest(a: std.mem.Allocator, path: []const u8, line: []const u8) ![]const u8 {
    const conn = try pnet.connectUnix(path);
    defer pnet.closeSocket(conn);
    try sendAll(conn, line);
    return readUntil(a, conn, "");
}

fn httpPost(a: std.mem.Allocator, port: u16, path: []const u8, body: []const u8) ![]const u8 {
    const conn = try pnet.connectLoopback(port);
    defer pnet.closeSocket(conn);
    try sendAll(conn, try std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ path, body.len, body }));
    return readUntil(a, conn, "HTTP/1.1 ");
}

fn journalLines(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "{\"v\":")) continue;
        try out.print(a, "{s}\n", .{line});
    }
    return out.items;
}

const daemon_scenario = "daemon_session";
const daemon_prompt = "read the notes";

fn checkDaemonRun(env: Env, checker: *Checker, scratch: *Scratch, server: *harness.MockServer, host: []const u8, journal: []const u8, sse_text: ?[]const u8) !void {
    const a = scratch.arena();
    const provider = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{server.port});
    const rules: normalize.Rules = .{ .literals = try literals(scratch, env, &.{.{ .needle = provider, .placeholder = "<PROVIDER>" }}) };
    const expected_dir = try std.fmt.allocPrint(a, "scenarios/{s}/expected/{s}", .{ daemon_scenario, host });
    if (env.mode == .update) try std.Io.Dir.cwd().deleteTree(io, try std.fs.path.join(a, &.{ env.contract_root, expected_dir }));
    try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, "journal.jsonl" }), try normalize.apply(a, journal, rules));
    if (sse_text) |text| try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, "events.sse" }), try normalize.apply(a, text, rules));
    for (0..server.requestCount()) |index| {
        const text = try renderRequest(a, server.requestAt(index).?.raw);
        const name = try std.fmt.allocPrint(a, "request-{d:0>3}.txt", .{index + 1});
        try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, name }), try normalize.apply(a, text, rules));
    }
}

fn startDaemonScenario(env: Env, scratch: *Scratch) !*harness.MockServer {
    const a = scratch.arena();
    const dir = try std.fs.path.join(a, &.{ env.contract_root, "scenarios", daemon_scenario });
    try copyTree(a, try std.fs.path.join(a, &.{ dir, "work" }), scratch.work, &.{});
    return harness.MockServer.startCassette(try loadCassette(a, dir), 0);
}

test "serve: the journal a UDS attach reads for one Run, and its provider requests" {
    const env = try Env.load();
    var checker: Checker = .{ .store = env.store() };
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    const a = scratch.arena();
    const server = try startDaemonScenario(env, &scratch);
    defer server.stop();
    const socket = try std.fs.path.join(a, &.{ scratch.root, "serve.sock" });
    var child = try spawnCli(&scratch, env, &.{ "--state-dir", scratch.state, "--api-key", "sk-contract", "--base-url", try server.urlOwned(a), "serve", "0", "--uds", socket, "--sessions", "1" });
    defer child.kill(io);

    pnet.closeSocket(try connectWhenReady(pnet.connectUnix, socket));
    const listed = try std.json.parseFromSliceLeaky(std.json.Value, a, try udsRequest(a, socket, "{\"op\":\"list\"}\n"), .{});
    const session = listed.object.get("sessions").?.array.items[0].string;
    const attach = try pnet.connectUnix(socket);
    defer pnet.closeSocket(attach);
    try sendAll(attach, try std.fmt.allocPrint(a, "{{\"op\":\"attach\",\"session\":\"{s}\",\"since\":0}}\n", .{session}));
    const accepted = try udsRequest(a, socket, try std.fmt.allocPrint(a, "{{\"op\":\"message\",\"session\":\"{s}\",\"text\":\"{s}\"}}\n", .{ session, daemon_prompt }));
    try testing.expect(std.mem.indexOf(u8, accepted, "\"ok\":true") != null);
    const journal = try readUntil(a, attach, "\"type\":\"run_done\"");
    try checkDaemonRun(env, &checker, &scratch, server, "serve", try journalLines(a, journal), null);
    try checker.finish();
}

test "--web: the journal GET /events streams for one Run, and its provider requests" {
    const env = try Env.load();
    var checker: Checker = .{ .store = env.store() };
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    const a = scratch.arena();
    const server = try startDaemonScenario(env, &scratch);
    defer server.stop();
    const probe = try pnet.listenLoopback(0, 1);
    const port = probe.port;
    pnet.closeSocket(probe.sock);
    var child = try spawnCli(&scratch, env, &.{ "--state-dir", scratch.state, "--api-key", "sk-contract", "--base-url", try server.urlOwned(a), "--web", try std.fmt.allocPrint(a, "{d}", .{port}) });
    defer child.kill(io);

    const events = try connectWhenReady(pnet.connectLoopback, port);
    defer pnet.closeSocket(events);
    try sendAll(events, "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    const accepted = try httpPost(a, port, "/message", "{\"text\":\"" ++ daemon_prompt ++ "\"}");
    try testing.expect(std.mem.startsWith(u8, accepted, "HTTP/1.1 200"));
    const raw = try readThrough(a, events, "\"type\":\"run_done\"", "\n\n");
    const response = sse.parse(a, raw) catch |err| {
        std.debug.print("GET /events is not a stream of SSE frames ({s}):\n{s}\n", .{ @errorName(err), raw });
        return err;
    };
    const journal = sse.journal(a, response) catch |err| {
        std.debug.print("GET /events frame carries more than one journal line ({s}):\n{s}\n", .{ @errorName(err), raw });
        return err;
    };
    try checkDaemonRun(env, &checker, &scratch, server, "web", journal, try sse.render(a, response));
    try checker.finish();
}

const sdk = @import("agentcore-sdk");
const wire = sdk.types;
const psync = @import("platform").sync;

const abi_scenario = "abi_session";

const AbiEvents = struct {
    mutex: psync.Mutex = .{},
    bytes: std.ArrayList(u8) = .empty,

    fn event(raw: ?*anyopaque, _: ?*const wire.RunContextV1, payload: wire.BytesViewV1) callconv(.c) u32 {
        const self: *AbiEvents = @ptrCast(@alignCast(raw.?));
        const bytes = sdk.borrowedBytes(payload) catch return wire.EVENT_CONTINUE;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.bytes.appendSlice(std.heap.c_allocator, bytes) catch {};
        self.bytes.append(std.heap.c_allocator, '\n') catch {};
        return wire.EVENT_CONTINUE;
    }

    fn take(self: *AbiEvents, a: std.mem.Allocator) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = try a.dupe(u8, self.bytes.items);
        self.bytes.clearRetainingCapacity();
        return out;
    }
};

const CheckpointBytes = struct {
    bytes: std.ArrayList(u8) = .empty,
    read_offset: usize = 0,

    fn sink(self: *CheckpointBytes) wire.CheckpointSinkV1 {
        var result = std.mem.zeroes(wire.CheckpointSinkV1);
        result.struct_size = @sizeOf(wire.CheckpointSinkV1);
        result.ctx = self;
        result.write = write;
        return result;
    }

    fn source(self: *CheckpointBytes) wire.CheckpointSourceV1 {
        self.read_offset = 0;
        var result = std.mem.zeroes(wire.CheckpointSourceV1);
        result.struct_size = @sizeOf(wire.CheckpointSourceV1);
        result.ctx = self;
        result.read = read;
        return result;
    }

    fn write(raw: ?*anyopaque, chunk: wire.BytesViewV1) callconv(.c) u32 {
        const self: *CheckpointBytes = @ptrCast(@alignCast(raw.?));
        const part = sdk.borrowedBytes(chunk) catch return wire.CHECKPOINT_IO_FATAL;
        self.bytes.appendSlice(std.heap.c_allocator, part) catch return wire.CHECKPOINT_IO_FATAL;
        return wire.CHECKPOINT_IO_OK;
    }

    fn read(raw: ?*anyopaque, destination: ?[*]u8, capacity: u64, out_len: ?*u64) callconv(.c) u32 {
        const self: *CheckpointBytes = @ptrCast(@alignCast(raw.?));
        const remaining = self.bytes.items[self.read_offset..];
        const count: usize = @min(@as(usize, @intCast(capacity)), remaining.len);
        if (count > 0) @memcpy(destination.?[0..count], remaining[0..count]);
        self.read_offset += count;
        out_len.?.* = count;
        return wire.CHECKPOINT_IO_OK;
    }
};

fn checkpointLimits() wire.CheckpointLimitsV1 {
    var limits = std.mem.zeroes(wire.CheckpointLimitsV1);
    limits.struct_size = @sizeOf(wire.CheckpointLimitsV1);
    limits.hard_bytes = 16 * 1024 * 1024;
    limits.max_section_bytes = 8 * 1024 * 1024;
    limits.max_string_bytes = 1024 * 1024;
    limits.max_messages = 1024;
    limits.max_blocks_per_message = 64;
    limits.chunk_bytes = 4096;
    return limits;
}

fn expectOk(api: sdk.Api, diagnostic: *wire.OwnedBytesV1, status: u32, what: []const u8) !void {
    if (status == wire.STATUS_OK) return;
    const text = sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch "";
    std.debug.print("AgentCore {s} returned status {d}: {s}\n", .{ what, status, text });
    api.bufferRelease()(diagnostic);
    return error.AgentCoreCallFailed;
}

fn runAbiText(api: sdk.Api, session: ?*wire.SessionHandle, run_id: u64, prompt: []const u8, diagnostic: *wire.OwnedBytesV1) !wire.RunResultV1 {
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 4;
    var result = std.mem.zeroes(wire.RunResultV1);
    try expectOk(api, diagnostic, api.session().runText(session, run_id, sdk.bytesView(prompt), &options, &result, diagnostic), "runText");
    return result;
}

test "AgentCore ABI: CoreEvents and requests of a Run, and restoring a checkpoint an earlier build exported" {
    const env = try Env.load();
    var checker: Checker = .{ .store = env.store() };
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    const a = scratch.arena();
    const dir = try std.fs.path.join(a, &.{ env.contract_root, "scenarios", abi_scenario });
    try copyTree(a, try std.fs.path.join(a, &.{ dir, "work" }), scratch.work, &.{});
    const server = try harness.MockServer.startCassette(try loadCassette(a, dir), 0);
    defer server.stop();
    const base_url = try server.urlOwned(a);

    var library = try std.DynLib.open(env.agentcore_shared);
    defer library.close();
    const get_api = library.lookup(*const fn (u32) callconv(.c) ?*const anyopaque, "metask_agentcore_get_api") orelse return error.MissingDiscoverySymbol;
    const api = try sdk.Api.validate(get_api(wire.ABI_VERSION_V1));

    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try expectOk(api, &diagnostic, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic), "runtime.create");
    defer _ = api.runtime().destroy()(runtime, &diagnostic);

    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("sk-contract");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(scratch.work);
    host.workspace_home = sdk.bytesView(scratch.home);
    var session_config = std.mem.zeroes(wire.SessionCreateConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    session_config.host = &host;
    session_config.model = sdk.bytesView("claude-sonnet-4-20250514");
    var events: AbiEvents = .{};
    defer events.bytes.deinit(std.heap.c_allocator);
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &events;
    callbacks.on_event = AbiEvents.event;

    var session: ?*wire.SessionHandle = null;
    try expectOk(api, &diagnostic, api.session().create()(runtime, &session_config, &callbacks, &session, &diagnostic), "session.create");
    const first = try runAbiText(api, session, 1, "read the notes", &diagnostic);
    const first_events = try events.take(a);

    var exported: CheckpointBytes = .{};
    defer exported.bytes.deinit(std.heap.c_allocator);
    var limits = checkpointLimits();
    var sink = exported.sink();
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try expectOk(api, &diagnostic, api.sessionControl().exportCheckpoint()(session, &export_config, &export_result, &diagnostic), "exportCheckpoint");
    try expectOk(api, &diagnostic, api.session().destroy()(session, &diagnostic), "session.destroy");
    session = null;

    const fixture_path = try std.fs.path.join(a, &.{ dir, "checkpoint.bin" });
    const fixture = std.Io.Dir.cwd().readFileAlloc(io, fixture_path, a, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => blk: {
            if (env.mode != .update) {
                std.debug.print("contract fixture missing: {s}\n", .{fixture_path});
                return error.ContractSnapshotMissing;
            }
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fixture_path, .data = exported.bytes.items });
            break :blk try a.dupe(u8, exported.bytes.items);
        },
        else => return err,
    };
    var stored: CheckpointBytes = .{};
    defer stored.bytes.deinit(std.heap.c_allocator);
    try stored.bytes.appendSlice(std.heap.c_allocator, fixture);
    var source = stored.source();
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &host;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var restore_report = std.mem.zeroes(wire.OwnedBytesV1);
    try expectOk(api, &diagnostic, api.sessionControl().restore()(runtime, &restore_config, &callbacks, &session, &restore_report, &diagnostic), "restore");
    const report = try a.dupe(u8, try sdk.borrowedBytes(.{ .ptr = restore_report.ptr, .len = restore_report.len }));
    api.bufferRelease()(&restore_report);
    const second = try runAbiText(api, session, 2, "what did the notes say?", &diagnostic);
    const second_events = try events.take(a);
    try expectOk(api, &diagnostic, api.session().destroy()(session, &diagnostic), "session.destroy");

    const provider = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{server.port});
    const rules: normalize.Rules = .{ .literals = try literals(&scratch, env, &.{.{ .needle = provider, .placeholder = "<PROVIDER>" }}) };
    const expected_dir = try std.fmt.allocPrint(a, "scenarios/{s}/expected", .{abi_scenario});
    if (env.mode == .update) try std.Io.Dir.cwd().deleteTree(io, try std.fs.path.join(a, &.{ env.contract_root, expected_dir }));
    var results: std.ArrayList(u8) = .empty;
    try results.print(a, "run: stop_reason {d}, turns {d}, tool_calls {d}\n", .{ first.stop_reason_code, first.turns, first.tool_calls });
    try results.print(a, "export: generation {d}\n", .{export_result.checkpoint_generation});
    try results.print(a, "restore report: {s}\n", .{report});
    try results.print(a, "run after restore: stop_reason {d}, turns {d}, tool_calls {d}\n", .{ second.stop_reason_code, second.turns, second.tool_calls });
    try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, "results.txt" }), try normalize.apply(a, results.items, rules));
    try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, "events-run.jsonl" }), try normalize.apply(a, first_events, rules));
    try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, "events-after-restore.jsonl" }), try normalize.apply(a, second_events, rules));
    for (0..server.requestCount()) |index| {
        const text = try renderRequest(a, server.requestAt(index).?.raw);
        const name = try std.fmt.allocPrint(a, "request-{d:0>3}.txt", .{index + 1});
        try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, name }), try normalize.apply(a, text, rules));
    }
    try checker.finish();
}

const kg_scenario = "kg_injection";

fn stopKgDaemon(scratch: *Scratch) void {
    const a = scratch.arena();
    const store = std.fs.path.join(a, &.{ scratch.state, "kg" }) catch return;
    const argv = [_]?[*:0]const u8{ "/usr/bin/env", "pkill", "-TERM", "-f", (a.dupeZ(u8, store) catch return).ptr, null };
    _ = cc.tools_common.spawnCaptureWithStderrTimed(&argv, a, null, 10_000, null, 0, null) catch {};
}

fn runKgStep(env: Env, checker: *Checker, scratch: *Scratch, step: []const u8, args: []const []const u8) !void {
    const a = scratch.arena();
    const dir = try std.fs.path.join(a, &.{ env.contract_root, "scenarios", kg_scenario, step });
    const server = try harness.MockServer.startCassette(try loadCassette(a, dir), 0);
    defer server.stop();
    var all_args: std.ArrayList([]const u8) = .empty;
    try all_args.appendSlice(a, &.{ "--state-dir", scratch.state, "--api-key", "sk-contract", "--base-url", try server.urlOwned(a), "--json", "--stream-json" });
    try all_args.appendSlice(a, args);
    const kg_env = [_][]const u8{
        "METACODES_KG_AUTOSTART=1",
        try std.fmt.allocPrint(a, "METACODES_KG_BIN={s}", .{env.tinykg}),
        try std.fmt.allocPrint(a, "METACODES_KGD_BIN={s}", .{env.tinykgd}),
    };
    const run = try runCli(scratch, env, &kg_env, all_args.items);
    const provider = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{server.port});
    const rules: normalize.Rules = .{ .literals = try literals(scratch, env, &.{
        .{ .needle = provider, .placeholder = "<PROVIDER>" },
        .{ .needle = env.tinykg, .placeholder = "<TINYKG>" },
        .{ .needle = env.tinykgd, .placeholder = "<TINYKGD>" },
    }) };
    const expected_dir = try std.fmt.allocPrint(a, "scenarios/{s}/expected/{s}", .{ kg_scenario, step });
    if (env.mode == .update) try std.Io.Dir.cwd().deleteTree(io, try std.fs.path.join(a, &.{ env.contract_root, expected_dir }));
    var process: std.ArrayList(u8) = .empty;
    try process.print(a, "exit: {d}\nrequests: {d}\n--- stderr\n{s}", .{ run.exit_code, server.requestCount(), run.stderr });
    try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, "process.txt" }), try normalize.apply(a, process.items, rules));
    try checkStream(checker, a, expected_dir, run.stdout, rules);
    for (0..server.requestCount()) |index| {
        const text = try renderRequest(a, server.requestAt(index).?.raw);
        const name = try std.fmt.allocPrint(a, "request-{d:0>3}.txt", .{index + 1});
        try checker.expect(a, try std.fs.path.join(a, &.{ expected_dir, name }), try normalize.apply(a, text, rules));
    }
}

test "KG injection: a memory stored through KgRemember enters the next session's request" {
    const env = try Env.load();
    var checker: Checker = .{ .store = env.store() };
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    defer stopKgDaemon(&scratch);
    try runKgStep(env, &checker, &scratch, "remember", &.{ "--allowedTools", "KgRemember", "-p", "remember that release branches are cut on Fridays" });
    try runKgStep(env, &checker, &scratch, "answer", &.{ "-p", "when are release branches cut?" });
    try checker.finish();
}
