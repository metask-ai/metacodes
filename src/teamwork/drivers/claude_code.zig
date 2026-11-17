//! The Claude Code seat driver (#521): a seat run as the `claude` CLI in
//! non-interactive mode, as a child process.
//!
//! - Executable: the seat's configured absolute `command`; never `PATH`.
//! - Compatibility: before the first run, `--version` must name Claude Code
//!   and `--help` must list every flag below (`required_help_text`); an
//!   incompatible CLI is `SeatError.spawn_failed`, with the reason written to
//!   `harness.log` in the seat directory and to the log.
//! - argv (pinned against Claude Code 2.1.323, see `pinned_version`):
//!   `<command> -p <bootstrap> --output-format stream-json --verbose
//!    --add-dir <seat dir> --permission-mode acceptEdits
//!    --permission-prompts none --no-session-persistence
//!    [--model <m>] [--effort <e>] [--max-budget-usd <remaining>]`.
//!   `acceptEdits` plus `--permission-prompts none` accepts edits inside the
//!   working directories and denies everything that would prompt.
//! - Working directory: the workspace. Environment: `env_allowlist` only, so
//!   no provider key of metacodes' (nor `ANTHROPIC_API_KEY`) reaches the
//!   child; Claude Code authenticates through its own login.
//! - Process group: the child leads its own group, killed whole on abort,
//!   timeout or wallclock budget, and swept after a normal exit so no
//!   descendant outlives the seat (POSIX; Windows kills the CLI alone).
//! - Sandbox: the CLI runs under the host's sandbox backend
//!   (`sandbox/exec.zig`: Seatbelt on macOS, bubblewrap on Linux) whose
//!   write roots are the workspace, the seat directory, the temp roots and
//!   Claude Code's own state under `~` (bwrap binds only the entries that
//!   exist when the seat starts). The network stays open: the CLI talks to
//!   its API unless the host restricts it. Compatibility probes run inside
//!   the same boundary. Without a working backend the launch is refused;
//!   only an explicit trusted `Options.sandbox=false` runs on the host.
//!   Under bwrap a CLI killed by signal N shows
//!   as bwrap's exit 128+N, mapped back to the signal
//!   (`WrappedCommand.childExitCode`).
//! - Result: stdout is read only for the last `result` event (status and
//!   `total_cost_usd`, charged as `harness_reported`). A missing cost report
//!   on a cost-bounded seat consumes its allowance as `reserved`; a `wallclock_only`
//!   seat is charged its wallclock. The handoff decides a clean exit
//!   (`run_dir.collectHandoff`); the transcript is never parsed.

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const pprocess = @import("platform").process;
const types = @import("../types.zig");
const run_dir = @import("../run_dir.zig");
const ledger_mod = @import("../ledger.zig");
const common = @import("common.zig");
const charters = @import("../charters.zig");
const write_scope = @import("write_scope.zig");
const sandbox_config = @import("../../sandbox/config.zig");
const worker_sandbox = @import("../../sandbox/worker.zig");
const util_time = @import("../../util/time.zig");
const log = @import("../../util/log.zig");

/// The Claude Code release the argv was pinned against (`claude --help`).
pub const pinned_version = "2.1.323";

/// What `--help` must contain for the argv this driver builds to mean what
/// it means here.
pub const required_help_text = [_][]const u8{
    "--print",
    "--output-format",
    "stream-json",
    "--verbose",
    "--add-dir",
    "--permission-mode",
    "acceptEdits",
    "--permission-prompts",
    "--no-session-persistence",
    "--model",
    "--effort",
    "--max-budget-usd",
    "--append-system-prompt",
    "--strict-mcp-config",
    "--mcp-config",
};

/// The variables passed to the CLI, by name; every other variable of the
/// runtime's environment (provider keys above all) is dropped.
pub const env_allowlist = [_][]const u8{
    "HOME",
    "USER",
    "LOGNAME",
    "PATH",
    "SHELL",
    "TERM",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TMPDIR",
    "TZ",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "NODE_EXTRA_CA_CERTS",
    "CLAUDE_CONFIG_DIR",
    "USERPROFILE",
    "APPDATA",
    "LOCALAPPDATA",
    "SystemRoot",
    "TEMP",
    "TMP",
};

/// The CLI's stderr and the driver's own diagnostics, in the seat directory.
pub const harness_log_file = "harness.log";

/// Claude Code's own state, writable inside the sandbox.
const claude_state_roots = [_][]const u8{ "~/.claude", "~/.claude.json", "~/.claude.json.backup", "~/.claude.json.lock" };

pub const Options = struct {
    /// The runtime's environment as `KEY=VALUE` entries
    /// (`platform.paths.environment`), borrowed; filtered by `env_allowlist`.
    parent_env: []const [:0]const u8,
    /// For `~` in the sandbox's write roots.
    home_dir: []const u8,
    /// Hard limit on one seat run, whatever its budget; null = none.
    timeout_ms: ?u64 = null,
    /// Limit on each compatibility probe.
    probe_timeout_ms: u64 = 15_000,
    /// Require the platform sandbox, including for compatibility probes.
    /// false is an explicit host opt-out, never an availability fallback.
    sandbox: bool = true,
    /// The host's read/write denials and network policy remain authoritative.
    /// Host write grants are not inherited by the worker.
    host_sandbox: ?*const sandbox_config.SandboxSettings = null,
};

/// The last `result` event of a stream-json run.
pub const ResultEvent = struct {
    subtype: Subtype,
    is_error: bool,
    cost_usd: ?f64,

    pub const Subtype = enum { success, error_max_budget_usd, error_max_turns, error_during_execution, other };
};

pub const ClaudeCodeDriver = struct {
    options: Options,
    binding: common.Binding,
    /// The probe verdict for the command last probed (one driver serves one
    /// seat, so one command).
    probed: ?Probe = null,

    const Probe = struct { ok: bool };

    pub fn init(options: Options, binding: common.Binding) ClaudeCodeDriver {
        return .{ .options = options, .binding = binding };
    }

    pub fn driver(self: *ClaudeCodeDriver) types.SeatDriver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: types.SeatDriver.VTable = .{ .run = runErased };

    fn runErased(
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        spec: *const types.SeatSpec,
        paths: types.SeatPaths,
        abort: *const types.AbortSignal,
    ) types.SeatDriver.Error!types.SeatOutcome {
        const self: *ClaudeCodeDriver = @ptrCast(@alignCast(ptr));
        return self.run(gpa, spec, paths, abort);
    }

    pub fn run(
        self: *ClaudeCodeDriver,
        gpa: std.mem.Allocator,
        spec: *const types.SeatSpec,
        paths: types.SeatPaths,
        abort: *const types.AbortSignal,
    ) types.SeatDriver.Error!types.SeatOutcome {
        const external = switch (spec.harness) {
            .claude_code => |external| external,
            .metacodes => {
                log.warn("teamwork", "seat {s}: Claude Code driver given a metacodes seat", .{self.binding.seat.slice()});
                return .{ .failed = .spawn_failed };
            },
        };
        if (abort.isAborted()) return .aborted;
        if (self.binding.ledger.isExhausted()) return .budget_exhausted;

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const seat_dir = common.seatDir(paths);
        var harness_log = HarnessLog.open(arena, seat_dir);
        defer harness_log.close();

        const env = try filterEnv(arena, self.options.parent_env);

        if (self.probed == null) {
            self.probed = .{ .ok = try self.probe(arena, external.command.bytes, env, paths.workspace, seat_dir, abort, &harness_log) };
        }
        if (!self.probed.?.ok) {
            if (abort.isAborted()) {
                self.probed = null;
                return .aborted;
            }
            return .{ .failed = .spawn_failed };
        }

        const remaining: ?f64 = switch (external.budget) {
            .cost => self.binding.ledger.remainingUsd(),
            .wallclock_only => null,
        };
        const base_argv = try buildArgv(arena, external.command.bytes, seat_dir, spec.model, spec.effort, remaining);
        const cli_argv = try arena.alloc([]const u8, base_argv.len + 5);
        @memcpy(cli_argv[0..base_argv.len], base_argv);
        cli_argv[base_argv.len] = "--append-system-prompt";
        cli_argv[base_argv.len + 1] = charters.forRole(spec.role);
        // Workers receive no orchestration channel from the user's own
        // Claude Code config, in particular no copy of the Manager endpoint.
        cli_argv[base_argv.len + 2] = "--strict-mcp-config";
        cli_argv[base_argv.len + 3] = "--mcp-config";
        cli_argv[base_argv.len + 4] = "{\"mcpServers\":{}}";

        var launch = self.prepareLaunch(gpa, cli_argv, paths.workspace, seat_dir) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            harness_log.print("sandbox setup failed: {s}\n", .{@errorName(err)});
            return .{ .failed = .spawn_failed };
        };
        defer launch.deinit();
        const argv = try nullTerminatedArgv(arena, launch.argv());

        const wallclock_deadline_ms: ?u64 = switch (external.budget) {
            .cost => null,
            .wallclock_only => |limit| @as(u64, limit.seconds) * 1000,
        };
        var sink: LineSink = .{ .gpa = gpa, .mode = .result_events };
        defer sink.deinit();
        if (external.budget == .cost) self.binding.ledger.reserve(self.binding.seat, .claude_code) catch return .budget_exhausted;
        const supervised = supervise(argv, env, paths.workspace, harness_log.fd, abort, .{
            .budget_ms = wallclock_deadline_ms,
            .timeout_ms = self.options.timeout_ms,
        }, &sink) catch |err| {
            harness_log.print("could not start {s}: {s}\n", .{ external.command.bytes, @errorName(err) });
            if (pprocess.takeLastSpawnFailure()) |failure| {
                var code_buf: [32]u8 = undefined;
                harness_log.print("  step {s}: {s}\n", .{ @tagName(failure.step), failure.describeCode(&code_buf) });
            }
            return .{ .failed = .spawn_failed };
        };
        if (sink.oom) return error.OutOfMemory;

        const cost: ledger_mod.Cost = switch (external.budget) {
            .wallclock_only => .wallclock_only,
            .cost => if (sink.result) |result|
                (if (result.cost_usd) |usd| .{ .harness_reported = usd } else .{ .reserved = remaining.? })
            else
                .{ .reserved = remaining.? },
        };
        const charged = common.charge(self.binding, .claude_code, supervised.elapsed_ms, cost);

        switch (supervised.stop) {
            .aborted => return .aborted,
            .budget => return .budget_exhausted,
            .timeout => {
                harness_log.print("killed after the {d} ms limit\n", .{self.options.timeout_ms orelse 0});
                return .{ .failed = .timed_out };
            },
            .exited => {},
        }
        if (charged == .unrecorded) return .budget_exhausted;
        if (sink.result) |result| if (result.subtype == .error_max_budget_usd) return .budget_exhausted;
        const raw_code = supervised.exit_code orelse 0;
        const code = launch.childExitCode(raw_code);
        if (code != 0) {
            if (builtin.os.tag != .windows and code < 0) return .{ .failed = .{ .signaled = @intCast(-code) } };
            return .{ .failed = .{ .exited = @truncate(@as(u32, @bitCast(code))) } };
        }
        if (external.budget == .cost and cost == .reserved) {
            harness_log.print("no usable cost report; the remaining dollar cap was reserved, not treated as zero spend\n", .{});
            return .budget_exhausted;
        }
        const result = sink.result orelse {
            harness_log.print("missing terminal result event\n", .{});
            return .{ .failed = .spawn_failed };
        };
        if (result.is_error or result.subtype != .success) {
            harness_log.print("CLI reported an unsuccessful terminal result\n", .{});
            return .{ .failed = .spawn_failed };
        }
        return run_dir.collectHandoff(gpa, paths.handoff);
    }

    /// `--version` must name Claude Code and `--help` must list every flag
    /// the argv uses. False (with the reason in the harness log) otherwise.
    fn probe(
        self: *ClaudeCodeDriver,
        arena: std.mem.Allocator,
        command: []const u8,
        env: []const [:0]const u8,
        cwd: []const u8,
        seat_dir: []const u8,
        abort: *const types.AbortSignal,
        harness_log: *HarnessLog,
    ) error{OutOfMemory}!bool {
        const version_out = (try self.capture(arena, &.{ command, "--version" }, env, cwd, seat_dir, abort, harness_log)) orelse return false;
        const version = parseVersion(version_out) orelse {
            harness_log.print("{s} --version did not identify Claude Code: {s}\n", .{ command, firstLine(version_out) });
            log.warn("teamwork", "seat {s}: {s} is not a Claude Code CLI", .{ self.binding.seat.slice(), command });
            return false;
        };
        const help_out = (try self.capture(arena, &.{ command, "--help" }, env, cwd, seat_dir, abort, harness_log)) orelse return false;
        for (required_help_text) |needle| {
            if (std.mem.indexOf(u8, help_out, needle) == null) {
                harness_log.print(
                    "Claude Code {s} at {s} is incompatible: its --help lacks `{s}` (argv pinned against {s})\n",
                    .{ version, command, needle, pinned_version },
                );
                log.warn("teamwork", "seat {s}: Claude Code {s} lacks {s} (pinned against {s})", .{ self.binding.seat.slice(), version, needle, pinned_version });
                return false;
            }
        }
        return true;
    }

    /// Stdout of a short probe run, or null when it could not run or failed.
    fn capture(
        self: *ClaudeCodeDriver,
        arena: std.mem.Allocator,
        argv_slices: []const []const u8,
        env: []const [:0]const u8,
        cwd: []const u8,
        seat_dir: []const u8,
        abort: *const types.AbortSignal,
        harness_log: *HarnessLog,
    ) error{OutOfMemory}!?[]const u8 {
        var launch = self.prepareLaunch(arena, argv_slices, cwd, seat_dir) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            harness_log.print("compatibility probe sandbox failed: {s}\n", .{@errorName(err)});
            return null;
        };
        defer launch.deinit();
        const argv = try nullTerminatedArgv(arena, launch.argv());
        var sink: LineSink = .{ .gpa = arena, .mode = .capture };
        const run_result = supervise(argv, env, cwd, harness_log.fd, abort, .{ .timeout_ms = self.options.probe_timeout_ms }, &sink) catch |err| {
            harness_log.print("could not start {s}: {s}\n", .{ argv_slices[0], @errorName(err) });
            if (pprocess.takeLastSpawnFailure()) |failure| {
                var code_buf: [32]u8 = undefined;
                harness_log.print("  step {s}: {s}\n", .{ @tagName(failure.step), failure.describeCode(&code_buf) });
            }
            log.warn("teamwork", "seat {s}: cannot run {s}", .{ self.binding.seat.slice(), argv_slices[0] });
            return null;
        };
        if (sink.oom) return error.OutOfMemory;
        if (run_result.stop != .exited or (run_result.exit_code orelse 1) != 0) {
            harness_log.print("{s} {s} did not succeed ({s}, exit {d})\n", .{ argv_slices[0], argv_slices[1], @tagName(run_result.stop), run_result.exit_code orelse -1 });
            return null;
        }
        return sink.captured.items;
    }

    fn prepareLaunch(self: *const ClaudeCodeDriver, gpa: std.mem.Allocator, argv: []const []const u8, cwd: []const u8, seat_dir: []const u8) !worker_sandbox.Launch {
        var settings: sandbox_config.SandboxSettings = .{
            .enabled = self.options.sandbox,
            .fail_if_unavailable = true,
            .allow_unsandboxed_commands = false,
            .auto_allow_bash_if_sandboxed = false,
            .allow_write = &claude_state_roots,
        };
        if (self.options.host_sandbox) |host| {
            settings.deny_read = host.deny_read;
            settings.allow_read = host.allow_read;
            settings.deny_write = host.deny_write;
            settings.allowed_domains = host.allowed_domains;
            settings.denied_domains = host.denied_domains;
        }
        const git_protection = try write_scope.GitProtection.init(gpa, cwd, settings.deny_write);
        defer git_protection.deinit();
        settings.deny_write = git_protection.roots;
        return worker_sandbox.prepare(gpa, argv, .{
            .cwd = cwd,
            .home = self.options.home_dir,
            .sandbox = &settings,
            .additional_dirs = &.{seat_dir},
        });
    }
};

// ── argv and environment ────────────────────────────────────────────────────

/// The CLI argv (see the module comment). Strings live in `arena`.
pub fn buildArgv(
    arena: std.mem.Allocator,
    command: []const u8,
    seat_dir: []const u8,
    model: ?[]const u8,
    effort: ?types.ReasoningEffort,
    max_budget_usd: ?f64,
) error{OutOfMemory}![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        command,
        "-p",
        common.bootstrap,
        "--output-format",
        "stream-json",
        "--verbose",
        // `--add-dir` takes several values: an option must follow it.
        "--add-dir",
        seat_dir,
        "--permission-mode",
        "acceptEdits",
        "--permission-prompts",
        "none",
        "--no-session-persistence",
    });
    if (model) |m| try argv.appendSlice(arena, &.{ "--model", m });
    if (effort) |e| try argv.appendSlice(arena, &.{ "--effort", effortFlag(e) });
    if (max_budget_usd) |usd| {
        // At least a micro-dollar: the ledger is not exhausted, so some budget
        // is left, and `0` would read as no budget at all.
        try argv.appendSlice(arena, &.{ "--max-budget-usd", try std.fmt.allocPrint(arena, "{d:.6}", .{@max(usd, 0.000001)}) });
    }
    return argv.toOwnedSlice(arena);
}

/// Claude Code's `--effort` levels are low, medium, high, xhigh and max;
/// metacodes' two levels below `low` map to `low`.
pub fn effortFlag(effort: types.ReasoningEffort) []const u8 {
    return switch (effort) {
        .none, .minimal, .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
        .max => "max",
    };
}

/// The allowlisted entries of `parent_env`, in their original order.
pub fn filterEnv(arena: std.mem.Allocator, parent_env: []const [:0]const u8) error{OutOfMemory}![]const [:0]const u8 {
    var out: std.ArrayList([:0]const u8) = .empty;
    for (parent_env) |entry| {
        const eq = std.mem.indexOfScalarPos(u8, entry, 1, '=') orelse continue;
        const name = entry[0..eq];
        for (env_allowlist) |allowed| {
            const same = if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(allowed, name) else std.mem.eql(u8, allowed, name);
            if (same) {
                try out.append(arena, entry);
                break;
            }
        }
    }
    return out.toOwnedSlice(arena);
}

/// `exec 'arg0' 'arg1' ...` for `/bin/bash -c`, each argument single-quoted.
fn nullTerminatedArgv(arena: std.mem.Allocator, argv: []const []const u8) error{OutOfMemory}![]const ?[*:0]const u8 {
    const out = try arena.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |arg, i| out[i] = (try arena.dupeZ(u8, arg)).ptr;
    out[argv.len] = null;
    return out;
}

/// `2.1.323 (Claude Code)` → `2.1.323`.
pub fn parseVersion(stdout: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, firstLine(stdout), " \t\r");
    const suffix = " (Claude Code)";
    if (!std.mem.endsWith(u8, line, suffix)) return null;
    const version = line[0 .. line.len - suffix.len];
    var parts = std.mem.splitScalar(u8, version, '.');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (part.len == 0) return null;
        for (part) |c| if (!std.ascii.isDigit(c)) return null;
    }
    return if (count == 3) version else null;
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

/// Parse one stream-json line; null unless it is a `result` event.
pub fn parseResultEvent(scratch: std.mem.Allocator, line: []const u8) ?ResultEvent {
    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch, line, .{}) catch return null;
    if (root != .object) return null;
    const obj = root.object;
    const kind = obj.get("type") orelse return null;
    if (kind != .string or !std.mem.eql(u8, kind.string, "result")) return null;
    const subtype: ResultEvent.Subtype = if (obj.get("subtype")) |value|
        (if (value == .string) std.meta.stringToEnum(ResultEvent.Subtype, value.string) orelse .other else .other)
    else
        .other;
    const is_error = if (obj.get("is_error")) |value| (value == .bool and value.bool) else false;
    const cost_usd: ?f64 = if (obj.get("total_cost_usd")) |value| switch (value) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    } else null;
    return .{ .subtype = subtype, .is_error = is_error, .cost_usd = cost_usd };
}

// ── child supervision ───────────────────────────────────────────────────────

const LineSink = struct {
    gpa: std.mem.Allocator,
    mode: enum { capture, result_events },
    /// `.capture`: all of stdout, up to `max_capture`.
    captured: std.ArrayList(u8) = .empty,
    /// `.result_events`: the current partial line and the last result seen.
    line: std.ArrayList(u8) = .empty,
    line_overflow: bool = false,
    result: ?ResultEvent = null,
    oom: bool = false,

    const max_capture = 1 << 20;
    /// A result event is small; a longer line is some other event.
    const max_line = 8 << 20;

    fn feed(self: *LineSink, bytes: []const u8) void {
        if (self.oom) return;
        switch (self.mode) {
            .capture => {
                const room = max_capture -| self.captured.items.len;
                self.captured.appendSlice(self.gpa, bytes[0..@min(room, bytes.len)]) catch {
                    self.oom = true;
                };
            },
            .result_events => {
                var rest = bytes;
                while (rest.len > 0) {
                    const nl = std.mem.indexOfScalar(u8, rest, '\n');
                    const chunk = rest[0 .. nl orelse rest.len];
                    if (!self.line_overflow) {
                        if (self.line.items.len + chunk.len > max_line) {
                            self.line_overflow = true;
                            self.line.clearRetainingCapacity();
                        } else {
                            self.line.appendSlice(self.gpa, chunk) catch {
                                self.oom = true;
                                return;
                            };
                        }
                    }
                    if (nl) |i| {
                        self.endLine();
                        rest = rest[i + 1 ..];
                    } else break;
                }
            },
        }
    }

    fn finish(self: *LineSink) void {
        if (self.mode == .result_events and self.line.items.len > 0) self.endLine();
    }

    fn endLine(self: *LineSink) void {
        defer {
            self.line.clearRetainingCapacity();
            self.line_overflow = false;
        }
        if (self.line_overflow) return;
        if (std.mem.indexOf(u8, self.line.items, "\"result\"") == null) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        if (parseResultEvent(arena.allocator(), self.line.items)) |event| self.result = event;
    }

    fn deinit(self: *LineSink) void {
        self.captured.deinit(self.gpa);
        self.line.deinit(self.gpa);
    }
};

const Limits = struct {
    /// The seat's wallclock budget, from spawn.
    budget_ms: ?u64 = null,
    /// The driver's hard limit, from spawn.
    timeout_ms: ?u64 = null,
};

const Supervised = struct {
    stop: enum { exited, aborted, budget, timeout },
    /// The child's own exit status (negative = killed by that signal, POSIX),
    /// null when the driver killed it and could not reap it.
    exit_code: ?i32,
    elapsed_ms: u64,
};

/// Spawn `argv` in its own process group and run it to the end, feeding
/// stdout to `sink`. Abort and the limits kill the whole group. After the
/// child exits on its own, its group is killed too, so no descendant
/// outlives the seat.
fn supervise(
    argv: []const ?[*:0]const u8,
    env: []const [:0]const u8,
    cwd: []const u8,
    stderr_fd: ?c_int,
    abort: *const types.AbortSignal,
    limits: Limits,
    sink: *LineSink,
) pprocess.CaptureError!Supervised {
    const started = util_time.nowMs();
    const child = try pprocess.spawnPipesWith(argv, .{ .env = env, .cwd = cwd, .stderr_fd = stderr_fd });
    child.closeStdin(); // the prompt is in argv; stdin is EOF
    var stdout_open = true;
    var exit_code: ?i32 = null;
    var drain_deadline: ?i64 = null;
    var buf: [64 * 1024]u8 = undefined;

    while (true) {
        const elapsed: u64 = @intCast(@max(util_time.nowMs() - started, 0));
        if (exit_code == null) {
            const stop: ?@FieldType(Supervised, "stop") = if (abort.isAborted() or sink.oom)
                .aborted
            else if (limits.budget_ms != null and elapsed >= limits.budget_ms.?)
                .budget
            else if (limits.timeout_ms != null and elapsed >= limits.timeout_ms.?)
                .timeout
            else
                null;
            if (stop) |reason| {
                child.killGroup();
                const code = reapAfterKill(&child);
                if (stdout_open) child.closeStdout();
                return .{ .stop = reason, .exit_code = code, .elapsed_ms = elapsed };
            }
        }

        if (stdout_open) {
            if (child.pollReadable(50)) {
                const n = child.read(&buf);
                if (n > 0) {
                    sink.feed(buf[0..@intCast(n)]);
                } else if (n < 0 and builtin.os.tag != .windows and pfs.lastErrnoIs(.INTR)) {
                    // interrupted: poll again
                } else {
                    child.closeStdout();
                    stdout_open = false;
                }
            }
        } else if (exit_code == null) {
            util_time.sleepMs(20);
        }

        if (exit_code == null) switch (child.tryWait()) {
            .running => {},
            .exited => |code| {
                exit_code = code;
                // Sweep whatever the child left running in its group.
                child.killGroup();
                drain_deadline = util_time.nowMs() + 2000;
            },
        };
        if (exit_code != null) {
            // A descendant that left the group may hold stdout open; do not
            // wait on it forever.
            if (stdout_open and util_time.nowMs() >= drain_deadline.?) {
                child.closeStdout();
                stdout_open = false;
            }
            if (!stdout_open) break;
        }
    }
    sink.finish();
    return .{
        .stop = .exited,
        .exit_code = exit_code,
        .elapsed_ms = @intCast(@max(util_time.nowMs() - started, 0)),
    };
}

/// Reap a child just sent SIGKILL (through its group), waiting a bounded time.
fn reapAfterKill(child: *const pprocess.PipeChild) ?i32 {
    var waited: u64 = 0;
    while (waited < 5000) : (waited += 10) {
        switch (child.tryWait()) {
            .exited => |code| return code,
            .running => util_time.sleepMs(10),
        }
    }
    return null;
}

const HarnessLog = struct {
    fd: ?c_int,

    fn open(arena: std.mem.Allocator, seat_dir: []const u8) HarnessLog {
        const path = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ seat_dir, harness_log_file }, 0) catch return .{ .fd = null };
        const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
        return .{ .fd = if (fd < 0) null else fd };
    }

    fn print(self: *HarnessLog, comptime fmt: []const u8, args: anytype) void {
        const fd = self.fd orelse return;
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print(fmt, args) catch {}; // a longer message is cut short
        _ = pfs.writeAll(fd, w.buffered());
    }

    fn close(self: *HarnessLog) void {
        if (self.fd) |fd| pfs.close(fd);
        self.fd = null;
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "claude code: argv is pinned, with model, effort and budget only when given" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bare = try buildArgv(arena, "/opt/claude", "/s/seats/implementer-1", null, null, null);
    const want_bare = [_][]const u8{
        "/opt/claude",
        "-p",
        "",
        "--output-format",
        "stream-json",
        "--verbose",
        "--add-dir",
        "/s/seats/implementer-1",
        "--permission-mode",
        "acceptEdits",
        "--permission-prompts",
        "none",
        "--no-session-persistence",
    };
    try testing.expectEqual(want_bare.len, bare.len);
    for (want_bare, bare, 0..) |want, got, i| {
        if (i == 2) try testing.expectEqualStrings(common.bootstrap, got) else try testing.expectEqualStrings(want, got);
    }
    const full = try buildArgv(arena, "/opt/claude", "/s", "claude-sonnet-5-5", .minimal, 1.25);
    try testing.expectEqualStrings("--model", full[13]);
    try testing.expectEqualStrings("claude-sonnet-5-5", full[14]);
    try testing.expectEqualStrings("--effort", full[15]);
    try testing.expectEqualStrings("low", full[16]);
    try testing.expectEqualStrings("--max-budget-usd", full[17]);
    try testing.expectEqualStrings("1.250000", full[18]);
}

test "claude code: environment allowlist drops provider keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parent = [_][:0]const u8{ "HOME=/h", "ANTHROPIC_API_KEY=sk-a", "PATH=/bin", "OPENAI_API_KEY=sk-o", "METACODES_HOME=/m", "LANG=C" };
    const env = try filterEnv(arena_state.allocator(), &parent);
    try testing.expectEqual(@as(usize, 3), env.len);
    try testing.expectEqualStrings("HOME=/h", env[0]);
    try testing.expectEqualStrings("PATH=/bin", env[1]);
    try testing.expectEqualStrings("LANG=C", env[2]);
}

test "claude code: version and result event parsing" {
    try testing.expectEqualStrings("2.1.323", parseVersion("2.1.323 (Claude Code)\n").?);
    try testing.expect(parseVersion("claude 2.1.323") == null);
    try testing.expect(parseVersion("2.1 (Claude Code)") == null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ok = parseResultEvent(arena, "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":0.42}").?;
    try testing.expectEqual(ResultEvent.Subtype.success, ok.subtype);
    try testing.expectEqual(@as(f64, 0.42), ok.cost_usd.?);
    const broke = parseResultEvent(arena, "{\"type\":\"result\",\"subtype\":\"error_max_budget_usd\",\"is_error\":true}").?;
    try testing.expectEqual(ResultEvent.Subtype.error_max_budget_usd, broke.subtype);
    try testing.expect(broke.cost_usd == null);
    try testing.expect(parseResultEvent(arena, "{\"type\":\"assistant\",\"message\":{\"content\":\"\\\"result\\\"\"}}") == null);
    try testing.expect(parseResultEvent(arena, "not json") == null);
}

test "claude code: stdout lines split across reads still yield the last result event" {
    var sink: LineSink = .{ .gpa = testing.allocator, .mode = .result_events };
    defer sink.deinit();
    sink.feed("{\"type\":\"system\"}\n{\"type\":\"res");
    sink.feed("ult\",\"subtype\":\"success\",\"total_cost_usd\":0.1}\n{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"total_cost_usd\":0.3}");
    sink.finish();
    try testing.expectEqual(ResultEvent.Subtype.error_max_turns, sink.result.?.subtype);
    try testing.expectEqual(@as(f64, 0.3), sink.result.?.cost_usd.?);
}

test "claude code: exec shell command quotes every argument" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try worker_sandbox.shellCommand(arena_state.allocator(), &.{ "/opt/claude", "it's", "a b" });
    try testing.expectEqualStrings("exec '/opt/claude' 'it'\\''s' 'a b'", text);
}
