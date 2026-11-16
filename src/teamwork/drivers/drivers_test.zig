//! L2 tests of the seat drivers (#515, #519, #520, #521): real child
//! processes (a fake `claude` shell script), a real run directory and
//! ledger, and a scripted provider driving the real metacodes subagent loop
//! with the real tools. Test-only; referenced from the test roots.
//!
//! POSIX only: the fake CLI is a `/bin/sh` script.

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const types = @import("../types.zig");
const config = @import("../config.zig");
const run_dir = @import("../run_dir.zig");
const ledger_mod = @import("../ledger.zig");
const charters = @import("../charters.zig");
const common = @import("common.zig");
const factory = @import("factory.zig");
const claude_code = @import("claude_code.zig");
const metacodes = @import("metacodes.zig");
const provider_mod = @import("../../api/provider.zig");
const api_stream = @import("../../api/stream.zig");
const json_mod = @import("../../json.zig");
const app_types = @import("../../types.zig");
const permission_mod = @import("../../permission.zig");
const tools_mod = @import("../../tools.zig");
const usage_mod = @import("../../core/usage.zig");
const reviewer = @import("../reviewer.zig");
const observation = @import("../../tools/observation.zig");
const swarm_team = @import("../../swarm/team.zig");
const util_fs = @import("../../util/fs.zig");
const util_time = @import("../../util/time.zig");
const log = @import("../../util/log.zig");

const testing = std.testing;
const PathBuf = [std.fs.max_path_bytes]u8;

const run_id_text = "r-7f3a9c";
const packet_text = "Task: add a --dry-run flag. Acceptance: see " ++ run_dir.seat_relative_original_request ++ ".\n";

/// The handoff both the scripted model and the fake CLI leave.
const handoff_text =
    \\# Handoff
    \\
    \\## Observation
    \\The flag parser lives in one place.
    \\
    \\## Reasoning
    \\One switch covers every caller.
    \\
    \\## Caveats
    \\None known.
    \\
    \\## Conclusion
    \\Added --dry-run.
    \\
    \\## Verification
    \\zig build test:units
    \\
;

// ── fixture ─────────────────────────────────────────────────────────────────

const Fixture = struct {
    root: run_dir.test_support.TestRoot,
    run: run_dir.RunDir,
    ledger: ledger_mod.Ledger,
    workspace_buf: PathBuf = undefined,
    workspace_len: usize = 0,
    state_buf: PathBuf = undefined,
    state_len: usize = 0,
    seats: [4]SeatFiles = undefined,
    seat_count: usize = 0,

    const SeatFiles = struct {
        id: types.SeatId,
        packet: PathBuf,
        packet_len: usize,
        handoff: PathBuf,
        handoff_len: usize,
    };

    fn init(self: *Fixture, tag: []const u8, cap_usd: f64) !void {
        self.* = .{ .root = run_dir.test_support.TestRoot.init(tag), .run = undefined, .ledger = undefined };
        errdefer self.root.deinit();
        self.state_len = (try std.fmt.bufPrint(&self.state_buf, "{s}/state", .{self.root.slice()})).len;
        self.workspace_len = (try std.fmt.bufPrint(&self.workspace_buf, "{s}/workspace", .{self.root.slice()})).len;
        try util_fs.mkdirParents(self.workspace());
        try util_fs.mkdirParents(self.state());
        self.run = try run_dir.RunDir.create(testing.allocator, self.state(), try types.RunId.parse(run_id_text));
        errdefer self.run.deinit(testing.allocator);
        try self.run.writeOriginalRequest("Add a --dry-run flag.\n");
        var budget_buf: run_dir.PathBuf = undefined;
        self.ledger = try ledger_mod.Ledger.load(testing.allocator, try self.run.path(&budget_buf, .budget), cap_usd);
    }

    fn deinit(self: *Fixture) void {
        self.ledger.deinit(testing.allocator);
        self.run.deinit(testing.allocator);
        self.root.deinit();
    }

    fn workspace(self: *const Fixture) []const u8 {
        return self.workspace_buf[0..self.workspace_len];
    }

    fn state(self: *const Fixture) []const u8 {
        return self.state_buf[0..self.state_len];
    }

    /// Record a new seat with `packet_text` and return its index.
    fn addSeat(self: *Fixture, role: types.Role, ordinal: u32, harness: types.Harness) !usize {
        const index = self.seat_count;
        self.seat_count += 1;
        const files = &self.seats[index];
        files.id = types.seatIdFor(role, ordinal);
        try self.run.createSeat(.{ .id = files.id, .role = role, .harness = harness, .status = .queued });
        try self.run.writePacket(files.id, packet_text);
        files.packet_len = (try self.run.seatPath(&files.packet, files.id, .packet)).len;
        files.handoff_len = (try self.run.seatPath(&files.handoff, files.id, .handoff)).len;
        return index;
    }

    fn paths(self: *const Fixture, index: usize) types.SeatPaths {
        const files = &self.seats[index];
        return .{
            .packet = files.packet[0..files.packet_len],
            .handoff = files.handoff[0..files.handoff_len],
            .workspace = self.workspace(),
        };
    }

    fn binding(self: *Fixture, index: usize) common.Binding {
        return .{ .ledger = &self.ledger, .seat = self.seats[index].id };
    }

    fn path(self: *const Fixture, buf: *PathBuf, rel: []const u8) [:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ self.root.slice(), rel }) catch unreachable;
    }

    fn lastLedgerLine(self: *const Fixture, gpa: std.mem.Allocator) ![]u8 {
        var buf: run_dir.PathBuf = undefined;
        const bytes = swarm_team.readFileAlloc(gpa, try self.run.path(&buf, .budget)) orelse return error.NoLedger;
        defer gpa.free(bytes);
        const trimmed = std.mem.trimEnd(u8, bytes, "\n");
        const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |nl| nl + 1 else 0;
        return gpa.dupe(u8, trimmed[start..]);
    }
};

// ── fake claude CLI ─────────────────────────────────────────────────────────

const fake_help =
    "Usage: claude [options] [command] [prompt]\n" ++
    "  -p, --print  --output-format <format> (\"text\", \"json\", \"stream-json\")  --verbose\n" ++
    "  --add-dir <directories...>  --permission-mode <mode> (\"acceptEdits\", \"dontAsk\")\n" ++
    "  --no-session-persistence  --model <model>  --effort <level>  --max-budget-usd <amount>\n";

const Scenario = enum {
    /// Writes the handoff, reports $0.25, exits 0.
    ok,
    /// Reports an error, exits 3, no handoff.
    exit_nonzero,
    /// Kills itself with SIGKILL.
    killed,
    /// Starts a grandchild in its group, records its pid, then hangs.
    hang,
    /// Reports success, exits 0, writes no handoff.
    no_handoff,
    /// Reports Claude Code's own budget stop.
    over_budget,
    /// Its `--help` lacks `--permission-prompts`.
    incompatible,
};

const FakeCli = struct {
    script: PathBuf = undefined,
    script_len: usize = 0,
    record: PathBuf = undefined,
    record_len: usize = 0,
    pidfile: PathBuf = undefined,
    pidfile_len: usize = 0,

    fn scriptPath(self: *const FakeCli) []const u8 {
        return self.script[0..self.script_len];
    }

    fn recordPath(self: *const FakeCli) [:0]const u8 {
        return self.record[0..self.record_len :0];
    }

    fn pidfilePath(self: *const FakeCli) [:0]const u8 {
        return self.pidfile[0..self.pidfile_len :0];
    }

    /// Install the fake as `<root>/bin/claude`; it records into the
    /// workspace (writable under any seat sandbox).
    fn install(self: *FakeCli, fx: *const Fixture, scenario: Scenario) !void {
        self.script_len = (try std.fmt.bufPrintZ(&self.script, "{s}/bin/claude", .{fx.root.slice()})).len;
        self.record_len = (try std.fmt.bufPrintZ(&self.record, "{s}/.fake-claude-record", .{fx.workspace()})).len;
        self.pidfile_len = (try std.fmt.bufPrintZ(&self.pidfile, "{s}/.fake-claude-grandchild", .{fx.workspace()})).len;
        var bin_buf: PathBuf = undefined;
        try util_fs.mkdirParents(fx.path(&bin_buf, "bin"));

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        const a = testing.allocator;
        try text.appendSlice(a, "#!/bin/sh\ncase \"$1\" in\n--version) echo '2.1.323 (Claude Code)'; exit 0 ;;\n--help) cat <<'HELP'\n");
        if (scenario == .incompatible) {
            try text.appendSlice(a, fake_help);
        } else {
            try text.appendSlice(a, fake_help);
            try text.appendSlice(a, "  --permission-prompts <target> (\"host\", \"none\")\n");
        }
        try text.appendSlice(a, "HELP\nexit 0 ;;\nesac\n");
        try text.print(a, "rec='{s}'\n", .{self.recordPath()});
        try text.appendSlice(a,
            \\printf 'argc:%s\n' "$#" > "$rec"
            \\for a in "$@"; do printf 'arg:%s\n' "$(printf '%s' "$a" | tr '\n' '|')" >> "$rec"; done
            \\printf 'cwd:%s\n' "$(pwd -P)" >> "$rec"
            \\env | sed 's/^/env:/' >> "$rec"
            \\seat=''
            \\prev=''
            \\for a in "$@"; do
            \\  if [ "$prev" = "--add-dir" ]; then seat="$a"; fi
            \\  prev="$a"
            \\done
            \\echo '{"type":"system","subtype":"init"}'
            \\
        );
        switch (scenario) {
            .ok => {
                try text.appendSlice(a, "cat > \"$seat/handoff.md\" <<'HANDOFF'\n");
                try text.appendSlice(a, handoff_text);
                try text.appendSlice(a, "HANDOFF\n");
                try text.appendSlice(a, "echo '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":0.25,\"result\":\"ok\"}'\nexit 0\n");
            },
            .exit_nonzero => try text.appendSlice(a, "echo '{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"total_cost_usd\":0.1}'\nexit 3\n"),
            .killed => try text.appendSlice(a, "kill -9 $$\n"),
            .hang => {
                try text.print(a, "sleep 300 &\necho $! > '{s}'\nsleep 300\n", .{self.pidfilePath()});
            },
            .no_handoff => try text.appendSlice(a, "echo '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":0.05}'\nexit 0\n"),
            .over_budget => try text.appendSlice(a, "echo '{\"type\":\"result\",\"subtype\":\"error_max_budget_usd\",\"is_error\":true,\"total_cost_usd\":0.5}'\nexit 1\n"),
            .incompatible => try text.appendSlice(a, "exit 0\n"),
        }

        const fd = pfs.open(@ptrCast(&self.script), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o755);
        if (fd < 0) return error.WriteFailed;
        defer pfs.close(fd);
        if (!pfs.writeAll(fd, text.items)) return error.WriteFailed;
        if (pfs.chmod(@ptrCast(&self.script), 0o755) != 0) return error.ChmodFailed;
    }

    fn readRecord(self: *const FakeCli, gpa: std.mem.Allocator) ?[]u8 {
        return swarm_team.readFileAlloc(gpa, self.recordPath());
    }
};

const parent_env = [_][:0]const u8{
    "HOME=/nonexistent-home",
    "PATH=/usr/bin:/bin",
    "LANG=C",
    "ANTHROPIC_API_KEY=sk-ant-secret",
    "OPENAI_API_KEY=sk-openai-secret",
    "METACODES_HOME=/should/not/leak",
};

fn claudeOptions() claude_code.Options {
    return .{ .parent_env = &parent_env, .home_dir = "/nonexistent-home" };
}

fn claudeSpec(command: []const u8, budget: types.BudgetEnforcement) !types.SeatSpec {
    return .{
        .role = .implementer,
        .harness = .{ .claude_code = .{ .command = try types.AbsolutePath.init(command), .budget = budget } },
    };
}

fn recordHas(record: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, record, '\n');
    while (it.next()) |got| if (std.mem.eql(u8, got, line)) return true;
    return false;
}

fn recordHasEnv(record: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, record, '\n');
    while (it.next()) |got| {
        if (std.mem.startsWith(u8, got, "env:") and std.mem.startsWith(u8, got[4..], name) and
            got.len > 4 + name.len and got[4 + name.len] == '=') return true;
    }
    return false;
}

/// The pid is gone (or a zombie awaiting its new parent's reap).
fn processGone(pid: std.c.pid_t) bool {
    var waited: u32 = 0;
    while (waited < 3000) : (waited += 20) {
        if (std.c.kill(pid, @enumFromInt(0)) != 0) return true;
        if (builtin.os.tag == .linux) {
            var path_buf: [64]u8 = undefined;
            const stat_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{pid}) catch return false;
            if (swarm_team.readFileAlloc(testing.allocator, stat_path)) |stat| {
                defer testing.allocator.free(stat);
                if (std.mem.lastIndexOfScalar(u8, stat, ')')) |close| {
                    if (close + 2 < stat.len and stat[close + 2] == 'Z') return true;
                }
            }
        }
        util_time.sleepMs(20);
    }
    return false;
}

// ── scripted provider ───────────────────────────────────────────────────────

pub const ScriptedProvider = struct {
    allocator: std.mem.Allocator,
    turns: []const []const Event,
    calls: usize = 0,
    step: usize = 0,
    /// Copies of what the first request carried.
    first_system: ?[]u8 = null,
    first_user: ?[]u8 = null,
    /// Every tool result the model was sent, concatenated.
    tool_results: std.ArrayList(u8) = .empty,

    pub const Event = union(enum) {
        text: []const u8,
        tool: struct { name: []const u8, input: []const u8 },
    };

    pub fn deinit(self: *ScriptedProvider) void {
        if (self.first_system) |s| self.allocator.free(s);
        if (self.first_user) |s| self.allocator.free(s);
        self.tool_results.deinit(self.allocator);
    }

    pub fn provider(self: *ScriptedProvider) provider_mod.Provider {
        return .{
            .ctx = self,
            .modelFn = model,
            .sendStreamFn = sendStream,
            .sendStreamRetryFn = sendStreamRetry,
            .sendFn = send,
            .maxTokensFn = maxTokens,
            .maxInputTokensFn = maxInputTokens,
            .reasoningEffortFn = reasoningEffort,
            .supportsFn = supports,
        };
    }

    fn cast(raw: *anyopaque) *ScriptedProvider {
        return @ptrCast(@alignCast(raw));
    }

    fn model(_: *anyopaque) []const u8 {
        return "scripted-seat-model";
    }

    fn currentTurn(self: *const ScriptedProvider) []const Event {
        const index = self.calls - 1;
        return if (index < self.turns.len) self.turns[index] else &.{.{ .text = "done" }};
    }

    fn sendStream(
        raw: *anyopaque,
        messages: []const app_types.ApiMessage,
        system: ?[]const u8,
        _: ?[]const json_mod.ToolDefinition,
        _: ?*const types.AbortSignal,
        _: ?[]const u8,
        _: ?json_mod.ToolChoice,
        _: []const u8,
    ) anyerror!provider_mod.StreamHandle {
        const self = cast(raw);
        if (self.calls == 0) {
            self.first_system = try self.allocator.dupe(u8, system orelse "");
            for (messages[0].content) |block| switch (block) {
                .text => |t| {
                    self.first_user = try self.allocator.dupe(u8, t);
                    break;
                },
                else => {},
            };
        }
        for (messages) |message| for (message.content) |block| switch (block) {
            .tool_result => |r| {
                try self.tool_results.appendSlice(self.allocator, r.content);
                try self.tool_results.append(self.allocator, '\n');
            },
            else => {},
        };
        self.calls += 1;
        self.step = 0;
        return .{
            .ctx = raw,
            .nextFn = next,
            .deinitFn = deinitStream,
            .stopReasonFn = stopReason,
            .requestIdFn = requestId,
        };
    }

    fn sendStreamRetry(
        raw: *anyopaque,
        messages: []const app_types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        abort: ?*const types.AbortSignal,
        model_override: ?[]const u8,
        tool_choice: ?json_mod.ToolChoice,
        _: u32,
        _: u64,
        _: ?provider_mod.RetryReporter,
        user_query: []const u8,
    ) anyerror!provider_mod.StreamHandle {
        return sendStream(raw, messages, system, tools, abort, model_override, tool_choice, user_query);
    }

    fn next(raw: *anyopaque) anyerror!?api_stream.StreamEvent {
        const self = cast(raw);
        const turn = self.currentTurn();
        const step = self.step;
        self.step += 1;
        if (step < turn.len) {
            return switch (turn[step]) {
                .text => |t| .{ .text = try self.allocator.dupe(u8, t) },
                .tool => |call| .{ .tool_use_start = .{
                    .id = try std.fmt.allocPrint(self.allocator, "tu_{d}_{d}", .{ self.calls, step }),
                    .name = try self.allocator.dupe(u8, call.name),
                    .input_json = try self.allocator.dupe(u8, call.input),
                } },
            };
        }
        if (step == turn.len) return .{ .usage = .{ .input_tokens = 1000, .output_tokens = 100 } };
        return null;
    }

    fn deinitStream(_: *anyopaque) void {}

    fn stopReason(raw: *anyopaque) api_stream.StopReason {
        const self = cast(raw);
        for (self.currentTurn()) |event| if (event == .tool) return .tool_use;
        return .end_turn;
    }

    fn requestId(_: *anyopaque) log.RequestId {
        return .{ .bytes = [_]u8{'s'} ** 12 };
    }

    fn send(
        _: *anyopaque,
        _: []const app_types.ApiMessage,
        _: ?[]const u8,
        _: ?[]const json_mod.ToolDefinition,
        _: ?[]const u8,
    ) anyerror!provider_mod.ApiResponse {
        return error.UnexpectedTestCall;
    }

    fn maxTokens(_: *anyopaque) u32 {
        return 32_000;
    }

    fn maxInputTokens(_: *anyopaque) u32 {
        return 200_000;
    }

    fn reasoningEffort(_: *anyopaque) ?app_types.ReasoningEffort {
        return null;
    }

    fn supports(_: *anyopaque, _: provider_mod.Capability) bool {
        return false;
    }
};

/// `{"file_path":"<path>","content":"<handoff_text, JSON-escaped>"}`.
fn writeHandoffInput(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "{{\"file_path\":\"{s}\",\"content\":\"", .{path});
    for (handoff_text) |c| switch (c) {
        '\n' => try out.appendSlice(gpa, "\\n"),
        '"' => try out.appendSlice(gpa, "\\\""),
        else => try out.append(gpa, c),
    };
    try out.appendSlice(gpa, "\"}");
    return out.toOwnedSlice(gpa);
}

const MetacodesHost = struct {
    arena: std.heap.ArenaAllocator,
    tool_defs: []json_mod.ToolDefinition,
    perm: permission_mod.PermissionContext,

    fn init(self: *MetacodesHost) !void {
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.tool_defs = try tools_mod.toToolDefinitions(self.arena.allocator());
        // The host itself would let everything through; the seat must not.
        self.perm = permission_mod.createContext(.bypass_permissions, testing.allocator);
    }

    fn deinit(self: *MetacodesHost) void {
        self.arena.deinit();
    }

    fn deps(self: *const MetacodesHost, prov: provider_mod.Provider, fx: *const Fixture) metacodes.Deps {
        return .{
            .provider = prov,
            .tool_defs = self.tool_defs,
            .permission_ctx = &self.perm,
            .home_dir = "/nonexistent-home",
            .state_root = fx.state(),
            .max_turns = 8,
        };
    }
};

fn expectSameHandoff(a: types.Handoff, b: types.Handoff) !void {
    inline for (std.meta.fields(types.HandoffSection)) |field| {
        const section: types.HandoffSection = @enumFromInt(field.value);
        try testing.expectEqualStrings(a.section(section), b.section(section));
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

test "teamwork drivers L2: switching a seat's harness in config switches the spawned child; same packet, same outcome shape" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // comptime: the rest is POSIX-only
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-drivers-switch", 5);
    defer fx.deinit();
    var fake: FakeCli = .{};
    try fake.install(&fx, .ok);

    // The same role, configured twice: first metacodes, then claude_code.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const local_cfg = try config.validate(try config.parse(arena,
        \\{"enabled":true,"budget_usd":5,"seats":{"implementer":{"harness":"metacodes"}}}
    , null), null);
    const external_text = try std.fmt.allocPrint(arena,
        \\{{"enabled":true,"budget_usd":5,"seats":{{"implementer":{{"harness":"claude_code","command":"{s}"}}}}}}
    , .{fake.scriptPath()});
    const external_cfg = try config.validate(try config.parse(arena, external_text, null), null);
    const local_spec = local_cfg.enabled.seats.getPtrConst(.implementer);
    const external_spec = external_cfg.enabled.seats.getPtrConst(.implementer);

    var host: MetacodesHost = undefined;
    try host.init();
    defer host.deinit();
    const local_seat = try fx.addSeat(.implementer, 1, .metacodes);
    const external_seat = try fx.addSeat(.implementer, 2, .claude_code);

    // metacodes seat: the scripted model writes the handoff in one Write call.
    const handoff_input = try writeHandoffInput(testing.allocator, fx.paths(local_seat).handoff);
    defer testing.allocator.free(handoff_input);
    const turns = [_][]const ScriptedProvider.Event{
        &.{.{ .tool = .{ .name = "Write", .input = handoff_input } }},
        &.{.{ .text = "Handoff written." }},
    };
    var scripted: ScriptedProvider = .{ .allocator = testing.allocator, .turns = &turns };
    defer scripted.deinit();
    const deps: factory.Deps = .{ .metacodes = host.deps(scripted.provider(), &fx), .claude_code = claudeOptions() };

    var abort = types.AbortSignal.init();
    var local_driver = factory.forSeat(local_spec, deps, fx.binding(local_seat));
    try testing.expectEqual(types.Harness.metacodes, local_driver.harness());
    var local_outcome = try local_driver.driver().run(testing.allocator, local_spec, fx.paths(local_seat), &abort);
    defer local_outcome.deinit(testing.allocator);
    try testing.expect(fake.readRecord(testing.allocator) == null); // no child process
    try testing.expectEqual(@as(usize, 2), scripted.calls);
    try testing.expectEqual(@as(usize, 1), fx.ledger.entries);
    var usage: usage_mod.UsageTotals = .{};
    usage.apply(.{ .input_tokens = 2000, .output_tokens = 200 });
    try testing.expectApproxEqAbs(usage.costUsd("scripted-seat-model"), fx.ledger.spent_usd, 1e-12);
    const local_line = try fx.lastLedgerLine(testing.allocator);
    defer testing.allocator.free(local_line);
    try testing.expect(std.mem.indexOf(u8, local_line, "\"harness\":\"metacodes\"") != null);
    try testing.expect(std.mem.indexOf(u8, local_line, "\"source\":\"provider_estimate\"") != null);

    // claude_code seat, same packet bytes.
    const remaining = fx.ledger.remainingUsd();
    const spent_before = fx.ledger.spent_usd;
    var external_driver = factory.forSeat(external_spec, deps, fx.binding(external_seat));
    try testing.expectEqual(types.Harness.claude_code, external_driver.harness());
    var external_outcome = try external_driver.driver().run(testing.allocator, external_spec, fx.paths(external_seat), &abort);
    defer external_outcome.deinit(testing.allocator);

    // Equally shaped outcomes from the two harnesses.
    try testing.expect(local_outcome == .finished);
    try testing.expect(external_outcome == .finished);
    try expectSameHandoff(local_outcome.finished, external_outcome.finished);

    // The child: exact argv, cwd = workspace, allowlisted environment.
    const record = fake.readRecord(testing.allocator) orelse return error.FakeNotRun;
    defer testing.allocator.free(record);
    var seat_dir_buf: run_dir.PathBuf = undefined;
    const seat_dir = try fx.run.seatDir(&seat_dir_buf, fx.seats[external_seat].id);
    var budget_buf: [64]u8 = undefined;
    const budget_arg = try std.fmt.bufPrint(&budget_buf, "{d:.6}", .{remaining});
    var bootstrap_line_buf: [4096]u8 = undefined;
    const bootstrap_line = try std.fmt.bufPrint(&bootstrap_line_buf, "arg:{s}", .{common.bootstrap});
    std.mem.replaceScalar(u8, bootstrap_line, '\n', '|');
    const want_args = [_][]const u8{
        fake.scriptPath(),      "-p",        bootstrap_line[4..],        "--output-format",   "stream-json",
        "--verbose",            "--add-dir", seat_dir,                   "--permission-mode", "acceptEdits",
        "--permission-prompts", "none",      "--no-session-persistence", "--max-budget-usd",  budget_arg,
    };
    try testing.expect(recordHas(record, "argc:14")); // $0 is not in "$@"
    for (want_args[1..]) |arg| {
        var line_buf: [4096]u8 = undefined;
        try testing.expect(recordHas(record, try std.fmt.bufPrint(&line_buf, "arg:{s}", .{arg})));
    }
    var ws_real_buf: PathBuf = undefined;
    var ws_z_buf: PathBuf = undefined;
    const ws_real = std.mem.span(pfs.finalPath(try std.fmt.bufPrintZ(&ws_z_buf, "{s}", .{fx.workspace()}), &ws_real_buf).?);
    var cwd_line_buf: [4096]u8 = undefined;
    try testing.expect(recordHas(record, try std.fmt.bufPrint(&cwd_line_buf, "cwd:{s}", .{ws_real})));
    try testing.expect(recordHasEnv(record, "HOME"));
    try testing.expect(recordHasEnv(record, "PATH"));
    try testing.expect(recordHasEnv(record, "LANG"));
    try testing.expect(!recordHasEnv(record, "ANTHROPIC_API_KEY"));
    try testing.expect(!recordHasEnv(record, "OPENAI_API_KEY"));
    try testing.expect(!recordHasEnv(record, "METACODES_HOME"));
    try testing.expect(std.mem.indexOf(u8, record, "secret") == null);

    // The reported cost is in the ledger, as the harness reported it.
    try testing.expectEqual(@as(usize, 2), fx.ledger.entries);
    try testing.expectApproxEqAbs(spent_before + 0.25, fx.ledger.spent_usd, 1e-12);
    const external_line = try fx.lastLedgerLine(testing.allocator);
    defer testing.allocator.free(external_line);
    try testing.expect(std.mem.indexOf(u8, external_line, "\"seat_id\":\"implementer-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, external_line, "\"harness\":\"claude_code\"") != null);
    try testing.expect(std.mem.indexOf(u8, external_line, "\"usd\":0.25") != null);
    try testing.expect(std.mem.indexOf(u8, external_line, "\"source\":\"harness_reported\"") != null);
}

test "teamwork drivers L2: metacodes seat cannot write outside its workspace and seat dir; bootstrap bytes are fixed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // comptime: the rest is POSIX-only
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-drivers-isolation", 5);
    defer fx.deinit();
    var host: MetacodesHost = undefined;
    try host.init();
    defer host.deinit();
    const seat = try fx.addSeat(.implementer, 1, .metacodes);
    const other_seat = try fx.addSeat(.reviewer, 1, .metacodes);

    var outside_buf: PathBuf = undefined;
    const outside = fx.path(&outside_buf, "outside.txt");
    var request_buf: run_dir.PathBuf = undefined;
    const original_request = try fx.run.path(&request_buf, .original_request);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const handoff_input = try writeHandoffInput(arena, fx.paths(seat).handoff);
    const turns = [_][]const ScriptedProvider.Event{
        &.{
            .{ .tool = .{ .name = "Write", .input = try std.fmt.allocPrint(arena, "{{\"file_path\":\"{s}\",\"content\":\"escaped\"}}", .{outside}) } },
            .{ .tool = .{ .name = "Write", .input = try std.fmt.allocPrint(arena, "{{\"file_path\":\"{s}\",\"content\":\"tampered\"}}", .{original_request}) } },
            .{ .tool = .{ .name = "Write", .input = try std.fmt.allocPrint(arena, "{{\"file_path\":\"{s}\",\"content\":\"forged\"}}", .{fx.paths(other_seat).handoff}) } },
            .{ .tool = .{ .name = "Write", .input = "{\"file_path\":\"../outside-relative.txt\",\"content\":\"escaped\"}" } },
            .{ .tool = .{ .name = "Write", .input = "{\"file_path\":\"notes/plan.md\",\"content\":\"inside\"}" } },
            .{ .tool = .{ .name = "Write", .input = handoff_input } },
        },
        &.{.{ .text = "Done." }},
    };
    var scripted: ScriptedProvider = .{ .allocator = testing.allocator, .turns = &turns };
    defer scripted.deinit();

    var driver_impl = metacodes.MetacodesDriver.init(host.deps(scripted.provider(), &fx), fx.binding(seat));
    const spec: types.SeatSpec = .{ .role = .implementer };
    var abort = types.AbortSignal.init();
    var outcome = try driver_impl.driver().run(testing.allocator, &spec, fx.paths(seat), &abort);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome == .finished);

    // Denied by mechanism: nothing landed outside the two roots.
    try testing.expect(!pfs.exists(outside.ptr));
    var rel_buf: PathBuf = undefined;
    try testing.expect(!pfs.exists(fx.path(&rel_buf, "outside-relative.txt").ptr));
    const request = try fx.run.readOriginalRequest(testing.allocator);
    defer testing.allocator.free(request);
    try testing.expectEqualStrings("Add a --dry-run flag.\n", request);
    var other_buf: PathBuf = undefined;
    try testing.expect(!pfs.exists(try std.fmt.bufPrintZ(&other_buf, "{s}", .{fx.paths(other_seat).handoff})));
    try testing.expect(std.mem.indexOf(u8, scripted.tool_results.items, "Denied") != null or
        std.mem.indexOf(u8, scripted.tool_results.items, "denied") != null);
    // ...while the workspace and the seat directory took their writes.
    var inside_buf: PathBuf = undefined;
    try testing.expect(pfs.exists(try std.fmt.bufPrintZ(&inside_buf, "{s}/notes/plan.md", .{fx.workspace()})));

    // Provider-visible bytes: the charter alone as system prompt, the fixed
    // bootstrap first; run id and state paths only in the environment block.
    try testing.expectEqualStrings(charters.forRole(.implementer), scripted.first_system.?);
    const first = scripted.first_user.?;
    try testing.expect(std.mem.startsWith(u8, first, common.bootstrap));
    const env_at = std.mem.indexOf(u8, first, metacodes.environment_open).?;
    try testing.expect(env_at >= common.bootstrap.len);
    const instruction = first[0..env_at];
    try testing.expect(std.mem.indexOf(u8, instruction, run_id_text) == null);
    try testing.expect(std.mem.indexOf(u8, instruction, fx.state()) == null);
    try testing.expect(std.mem.indexOf(u8, instruction, fx.root.slice()) == null);
    try testing.expect(std.mem.indexOf(u8, scripted.first_system.?, run_id_text) == null);
    try testing.expect(std.mem.indexOf(u8, first[env_at..], "seat directory: ") != null);
}

test "teamwork drivers L2: claude seat failures map to outcomes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // comptime: the rest is POSIX-only
    const cases = [_]struct { scenario: Scenario, check: *const fn (types.SeatOutcome) anyerror!void }{
        .{ .scenario = .exit_nonzero, .check = struct {
            fn f(o: types.SeatOutcome) !void {
                try testing.expectEqual(@as(u8, 3), o.failed.exited);
            }
        }.f },
        .{ .scenario = .killed, .check = struct {
            fn f(o: types.SeatOutcome) !void {
                try testing.expectEqual(@as(u32, 9), o.failed.signaled);
            }
        }.f },
        .{ .scenario = .no_handoff, .check = struct {
            fn f(o: types.SeatOutcome) !void {
                try testing.expect(o.failed == .handoff_missing);
            }
        }.f },
        .{ .scenario = .over_budget, .check = struct {
            fn f(o: types.SeatOutcome) !void {
                try testing.expect(o == .budget_exhausted);
            }
        }.f },
        .{ .scenario = .incompatible, .check = struct {
            fn f(o: types.SeatOutcome) !void {
                try testing.expect(o.failed == .spawn_failed);
            }
        }.f },
    };
    for (cases) |case| {
        var fx: Fixture = undefined;
        try fx.init("cc-zig-teamwork-drivers-fail", 5);
        defer fx.deinit();
        var fake: FakeCli = .{};
        try fake.install(&fx, case.scenario);
        const seat = try fx.addSeat(.implementer, 1, .claude_code);
        const spec = try claudeSpec(fake.scriptPath(), .cost);
        var impl = claude_code.ClaudeCodeDriver.init(claudeOptions(), fx.binding(seat));
        var abort = types.AbortSignal.init();
        var outcome = try impl.driver().run(testing.allocator, &spec, fx.paths(seat), &abort);
        defer outcome.deinit(testing.allocator);
        case.check(outcome) catch |err| {
            std.debug.print("scenario {s}: outcome {any}\n", .{ @tagName(case.scenario), outcome });
            return err;
        };
        if (case.scenario == .incompatible) {
            // The CLI never ran a seat, and the reason is on record.
            try testing.expect(fake.readRecord(testing.allocator) == null);
            var log_buf: PathBuf = undefined;
            var seat_dir_buf: run_dir.PathBuf = undefined;
            const log_path = try std.fmt.bufPrintZ(&log_buf, "{s}/{s}", .{ try fx.run.seatDir(&seat_dir_buf, fx.seats[seat].id), claude_code.harness_log_file });
            const text = swarm_team.readFileAlloc(testing.allocator, log_path) orelse return error.NoHarnessLog;
            defer testing.allocator.free(text);
            try testing.expect(std.mem.indexOf(u8, text, "--permission-prompts") != null);
            try testing.expect(std.mem.indexOf(u8, text, claude_code.pinned_version) != null);
            try testing.expectEqual(@as(usize, 0), fx.ledger.entries);
        } else {
            try testing.expectEqual(@as(usize, 1), fx.ledger.entries);
        }
    }
}

test "teamwork drivers L2: claude seat timeout, wallclock budget and abort kill the whole group" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // comptime: the rest is POSIX-only
    const Mode = enum { timeout, wallclock, abort };
    for ([_]Mode{ .timeout, .wallclock, .abort }) |mode| {
        var fx: Fixture = undefined;
        try fx.init("cc-zig-teamwork-drivers-kill", 5);
        defer fx.deinit();
        var fake: FakeCli = .{};
        try fake.install(&fx, .hang);
        const seat = try fx.addSeat(.implementer, 1, .claude_code);
        const spec = try claudeSpec(fake.scriptPath(), switch (mode) {
            .wallclock => .{ .wallclock_only = .{ .seconds = 1 } },
            .timeout, .abort => .cost,
        });
        var options = claudeOptions();
        if (mode == .timeout) options.timeout_ms = 800;
        var impl = claude_code.ClaudeCodeDriver.init(options, fx.binding(seat));
        var abort = types.AbortSignal.init();

        const Aborter = struct {
            fn run(signal: *types.AbortSignal, pidfile: [*:0]const u8) void {
                var waited: u32 = 0;
                while (waited < 10_000 and !pfs.exists(pidfile)) : (waited += 20) util_time.sleepMs(20);
                util_time.sleepMs(100);
                signal.abort(.user_interrupt);
            }
        };
        var thread: ?std.Thread = null;
        if (mode == .abort) thread = try std.Thread.spawn(.{}, Aborter.run, .{ &abort, fake.pidfilePath().ptr });
        const started = util_time.nowMs();
        var outcome = try impl.driver().run(testing.allocator, &spec, fx.paths(seat), &abort);
        defer outcome.deinit(testing.allocator);
        if (thread) |t| t.join();
        const elapsed = util_time.nowMs() - started;

        switch (mode) {
            .timeout => try testing.expect(outcome.failed == .timed_out),
            .wallclock => try testing.expect(outcome == .budget_exhausted),
            .abort => try testing.expect(outcome == .aborted),
        }
        try testing.expect(elapsed < 20_000);

        // The grandchild the CLI left behind died with its group.
        const pid_text = swarm_team.readFileAlloc(testing.allocator, fake.pidfilePath()) orelse return error.NoGrandchild;
        defer testing.allocator.free(pid_text);
        const pid = try std.fmt.parseInt(std.c.pid_t, std.mem.trim(u8, pid_text, " \n"), 10);
        try testing.expect(processGone(pid));

        // Spend is charged even for a killed seat: its wallclock.
        try testing.expectEqual(@as(usize, 1), fx.ledger.entries);
        const line = try fx.lastLedgerLine(testing.allocator);
        defer testing.allocator.free(line);
        try testing.expect(std.mem.indexOf(u8, line, "\"source\":\"wallclock_only\"") != null);
        if (mode == .wallclock) try testing.expect(fx.ledger.wallclock_ms >= 1000);
    }
}

/// Records every Bash dispatch the seat's tool observer is tapped with.
const TapRecorder = struct {
    gpa: std.mem.Allocator,
    mutex: @import("platform").sync.Mutex = .{},
    bash_inputs: std.ArrayList([]u8) = .empty,

    fn deinit(self: *TapRecorder) void {
        for (self.bash_inputs.items) |input| self.gpa.free(input);
        self.bash_inputs.deinit(self.gpa);
    }

    fn sink(self: *TapRecorder) observation.Sink {
        return .{ .ctx = self, .emitFn = emit, .tapFn = tap };
    }

    fn emit(_: *anyopaque, _: observation.Event) bool {
        return true;
    }

    fn tap(ctx: *anyopaque, dispatch: observation.DispatchTap) void {
        const self: *TapRecorder = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, dispatch.dispatched_name, "Bash")) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        const copy = self.gpa.dupe(u8, dispatch.input) catch return;
        self.bash_inputs.append(self.gpa, copy) catch self.gpa.free(copy);
    }
};

test "teamwork drivers L2: a metacodes reviewer seat taps the plugged-in tool observer and cannot edit the workspace" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // comptime: the rest is POSIX-only
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-drivers-reviewer", 5);
    defer fx.deinit();
    var host: MetacodesHost = undefined;
    try host.init();
    defer host.deinit();
    const seat = try fx.addSeat(.reviewer, 1, .metacodes);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const turns = [_][]const ScriptedProvider.Event{
        &.{
            .{ .tool = .{ .name = "Bash", .input = "{\"command\":\"ls\"}" } },
            .{ .tool = .{ .name = "Write", .input = "{\"file_path\":\"src/fix.zig\",\"content\":\"reviewer edit\"}" } },
            .{ .tool = .{ .name = "Edit", .input = "{\"file_path\":\"src/fix.zig\",\"old_string\":\"a\",\"new_string\":\"b\"}" } },
            .{ .tool = .{ .name = "Write", .input = try writeHandoffInput(arena, fx.paths(seat).handoff) } },
        },
        &.{.{ .text = "Reviewed." }},
    };
    var scripted: ScriptedProvider = .{ .allocator = testing.allocator, .turns = &turns };
    defer scripted.deinit();

    var recorder: TapRecorder = .{ .gpa = testing.allocator };
    defer recorder.deinit();
    var driver_impl = metacodes.MetacodesDriver.init(host.deps(scripted.provider(), &fx), fx.binding(seat));
    driver_impl.tool_observer = recorder.sink();
    // The reviewer's own log plugs into the same slot.
    var calls = reviewer.BashCallLog.init(testing.allocator, null);
    defer calls.deinit();
    const log_slot: @TypeOf(driver_impl.tool_observer) = calls.sink();
    _ = log_slot;

    const spec: types.SeatSpec = .{ .role = .reviewer };
    var abort = types.AbortSignal.init();
    var outcome = try driver_impl.driver().run(testing.allocator, &spec, fx.paths(seat), &abort);
    defer outcome.deinit(testing.allocator);

    try testing.expect(outcome == .finished);
    try testing.expectEqualStrings(reviewer.charter, scripted.first_system.?);
    try testing.expectEqual(@as(usize, 1), recorder.bash_inputs.items.len);
    try testing.expect(std.mem.indexOf(u8, recorder.bash_inputs.items[0], "\"ls\"") != null);
    // A reviewer's Write/Edit cannot reach the workspace.
    var edit_buf: PathBuf = undefined;
    try testing.expect(!pfs.exists(try std.fmt.bufPrintZ(&edit_buf, "{s}/src/fix.zig", .{fx.workspace()})));
    try testing.expect(std.mem.indexOf(u8, scripted.tool_results.items, "outside the current execution policy") != null);
}
