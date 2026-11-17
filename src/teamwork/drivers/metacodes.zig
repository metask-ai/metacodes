//! The metacodes seat driver (#515): a seat run as an in-process metacodes
//! subagent (`core/subagent.zig` `spawnAgentSink`).
//!
//! - System prompt: the role charter (`charters.forRole`), nothing else.
//! - First user message: the fixed `common.bootstrap` text, then an
//!   environment block naming the workspace and the seat directory (the
//!   counterpart of Claude Code's `--add-dir` environment section). Run ids,
//!   timestamps and state paths never enter the bootstrap or the charter.
//! - Working directory: the workspace, with relative paths resolved against
//!   it; the seat directory is the one additional directory.
//! - Write isolation: `write_scope.zig` (execution policy, permission scope,
//!   Bash sandbox).
//! - Budget: the child's `cost_budget_usd` is what is left of the run cap;
//!   afterwards the child's own usage estimate is charged to the ledger
//!   (`provider_estimate`).
//! - Result: after the child stops on its own, the handoff decides
//!   (`run_dir.collectHandoff`), as for every harness.

const std = @import("std");
const types = @import("../types.zig");
const run_dir = @import("../run_dir.zig");
const charters = @import("../charters.zig");
const common = @import("common.zig");
const write_scope = @import("write_scope.zig");
const subagent = @import("../../core/subagent.zig");
const provider_mod = @import("../../api/provider.zig");
const client_mod = @import("../../client.zig");
const json_mod = @import("../../json.zig");
const permission_mod = @import("../../permission.zig");
const sandbox_config = @import("../../sandbox/config.zig");
const sandbox_exec = @import("../../sandbox/exec.zig");
const writer_backend = @import("../../core/writer_backend.zig");
const tool_context = @import("../../tools/context.zig");
const usage_mod = @import("../../core/usage.zig");
const SessionId = @import("../../core/session_id.zig").SessionId;
const util_time = @import("../../util/time.zig");
const log = @import("../../util/log.zig");

/// What a metacodes seat runs on, all borrowed for the driver's life.
pub const Deps = struct {
    provider: provider_mod.Provider,
    /// For Anthropic server tools; null for any other provider.
    anthropic_client: ?*client_mod.Client = null,
    /// The host's tool definitions; the seat is offered only its role's
    /// tools among them (`write_scope.toolsFor`).
    tool_defs: []const json_mod.ToolDefinition,
    /// The host's permission context. The seat derives its own from it:
    /// deny rules, settings and hooks still apply; mode, working directories,
    /// prompt channel and session memory are the seat's.
    permission_ctx: *const permission_mod.PermissionContext,
    /// The host's sandbox settings, whose read restrictions the seat keeps
    /// (`write_scope.seatSandbox`); null = none.
    host_sandbox: ?*const sandbox_config.SandboxSettings = null,
    home_dir: []const u8,
    state_root: []const u8,
    artifact_root: []const u8 = "",
    /// UI/event routing identity of the runtime's session.
    session: SessionId = .single,
    max_turns: u32 = 200,
};

pub const MetacodesDriver = struct {
    deps: Deps,
    binding: common.Binding,
    /// An extra observer of the seat's tool dispatches, borrowed for the
    /// seat's run: a reviewer seat's `reviewer.BashCallLog.sink()`, so the
    /// runtime can check the review's evidence against what really ran.
    tool_observer: ?tool_context.ToolObservationSink = null,

    pub fn init(deps: Deps, binding: common.Binding) MetacodesDriver {
        return .{ .deps = deps, .binding = binding };
    }

    pub fn driver(self: *MetacodesDriver) types.SeatDriver {
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
        const self: *MetacodesDriver = @ptrCast(@alignCast(ptr));
        return self.run(gpa, spec, paths, abort);
    }

    pub fn run(
        self: *MetacodesDriver,
        gpa: std.mem.Allocator,
        spec: *const types.SeatSpec,
        paths: types.SeatPaths,
        abort: *const types.AbortSignal,
    ) types.SeatDriver.Error!types.SeatOutcome {
        if (spec.harness != .metacodes) {
            log.warn("teamwork", "seat {s}: metacodes driver given a {s} seat", .{ self.binding.seat.slice(), spec.harnessKind().name() });
            return .{ .failed = .spawn_failed };
        }
        if (abort.isAborted()) return .aborted;
        if (self.binding.ledger.isExhausted()) return .budget_exhausted;
        if (!sandbox_exec.hostSupported()) {
            log.warn("teamwork", "seat {s}: required sandbox is unavailable", .{self.binding.seat.slice()});
            return .{ .failed = .spawn_failed };
        }

        const seat_dir = common.seatDir(paths);
        var seat_sandbox = write_scope.seatSandbox(self.deps.host_sandbox);
        const git_protection = try write_scope.GitProtection.init(gpa, paths.workspace, seat_sandbox.deny_write);
        defer git_protection.deinit();
        seat_sandbox.deny_write = git_protection.roots;
        var scope: write_scope.Scope = undefined;
        scope.init(spec.role, paths.workspace, seat_dir, self.deps.home_dir, &seat_sandbox) catch |err| {
            log.warn("teamwork", "seat {s}: workspace or seat directory unusable: {s}", .{ self.binding.seat.slice(), @errorName(err) });
            return .{ .failed = .spawn_failed };
        };
        const policy = scope.executionPolicy();

        const tool_defs = try seatToolDefs(gpa, self.deps.tool_defs, write_scope.toolsFor(spec.role));
        defer gpa.free(tool_defs);

        const additional_dirs = [_][]const u8{seat_dir};
        var perm = seatPermission(self.deps.permission_ctx, paths.workspace, self.deps.home_dir, &additional_dirs, &seat_sandbox);

        const prompt = try firstMessage(gpa, paths.workspace, seat_dir);
        defer gpa.free(prompt);

        var usage: usage_mod.UsageTotals = .{};
        var sink = writer_backend.WriterBackend.initNullWithUsage(&usage);
        const backend = sink.backend();

        self.binding.ledger.reserve(self.binding.seat, .metacodes) catch return .budget_exhausted;

        const started_ms = util_time.nowMs();
        const result = subagent.spawnAgentSink(
            gpa,
            self.deps.provider,
            self.deps.anthropic_client,
            tool_defs,
            &perm,
            abort,
            prompt,
            .{
                .max_turns = self.deps.max_turns,
                .system_prompt = charters.forRole(spec.role),
                .cost_budget_usd = self.binding.ledger.remainingUsd(),
                .session = self.deps.session,
                .tool_defs_override = tool_defs,
                .permission_mode_override = .accept_edits,
                .model_override = spec.model,
                .reasoning_effort_override = spec.effort,
                .execution_policy = policy,
                .tool_observer = self.tool_observer,
                .project_dir = paths.workspace,
                .sandbox = &seat_sandbox,
                .cwd_abs = paths.workspace,
                .resolve_relative_paths = true,
                .home_dir = self.deps.home_dir,
                .state_root = self.deps.state_root,
                .artifact_root = self.deps.artifact_root,
                .additional_dirs = &additional_dirs,
            },
            &backend,
        );
        const wallclock_ms: u64 = @intCast(@max(util_time.nowMs() - started_ms, 0));

        // Whatever happened, the provider calls made so far are spent.
        const model = spec.model orelse self.deps.provider.model();
        const charged = common.charge(self.binding, .metacodes, wallclock_ms, .{ .provider_estimate = usage.costUsd(model) });

        const sub = result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("teamwork", "seat {s}: metacodes subagent failed to run: {s}", .{ self.binding.seat.slice(), @errorName(err) });
                if (abort.isAborted()) return .aborted;
                return .{ .failed = .spawn_failed };
            },
        };
        defer sub.deinit();

        if (sub.stop_reason == .aborted or abort.isAborted()) return .aborted;
        if (sub.stop_reason == .budget or charged == .unrecorded) return .budget_exhausted;
        // A seat that stopped on its own is judged by its handoff, like any
        // harness that exited cleanly. A run cap the charge just reached is
        // the runtime's to act on (`Ledger.isExhausted`); the finished work
        // is still reported.
        return run_dir.collectHandoff(gpa, paths.handoff);
    }
};

/// The host tool definitions named in `names`, in host order. The slice is
/// owned by `gpa`; the definitions are borrowed.
pub fn seatToolDefs(
    gpa: std.mem.Allocator,
    host: []const json_mod.ToolDefinition,
    names: []const []const u8,
) error{OutOfMemory}![]json_mod.ToolDefinition {
    var out: std.ArrayList(json_mod.ToolDefinition) = .empty;
    errdefer out.deinit(gpa);
    for (host) |def| {
        for (names) |name| if (std.mem.eql(u8, name, def.name)) {
            try out.append(gpa, def);
            break;
        };
    }
    return out.toOwnedSlice(gpa);
}

/// The seat's permission context: the host's rules, settings and hooks, but
/// the seat's two working directories, its sandbox, and no prompt channel,
/// memdir exemption or remembered session grants. `spawnAgentSink` then puts
/// it in `acceptEdits`.
pub fn seatPermission(
    host: *const permission_mod.PermissionContext,
    workspace: []const u8,
    home: []const u8,
    additional_dirs: []const []const u8,
    sandbox: *const sandbox_config.SandboxSettings,
) permission_mod.PermissionContext {
    var perm = host.scopedDerive(.accept_edits);
    perm.match_ctx.cwd = workspace;
    perm.match_ctx.project_root = workspace;
    perm.match_ctx.home = home;
    perm.match_ctx.additional_dirs = additional_dirs;
    perm.sandbox = sandbox;
    perm.ui_requester = null;
    perm.no_interactive_prompt = true;
    perm.session_rules = null;
    perm.memdir_abs = "";
    return perm;
}

pub const environment_open = "<seat-environment>\n";
pub const environment_close = "</seat-environment>\n";

/// The seat's first user message: the fixed bootstrap, then the
/// environment block. Owned by `gpa`.
pub fn firstMessage(gpa: std.mem.Allocator, workspace: []const u8, seat_dir: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{s}\n" ++ environment_open ++ "workspace (current working directory): {s}\nseat directory: {s}\n" ++ environment_close,
        .{ common.bootstrap, workspace, seat_dir },
    );
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "metacodes driver: seat tool set is a filter of the host's, in order" {
    const host = [_]json_mod.ToolDefinition{
        .{ .name = "Agent", .description = "", .input_schema = .{} },
        .{ .name = "Read", .description = "", .input_schema = .{} },
        .{ .name = "WebFetch", .description = "", .input_schema = .{} },
        .{ .name = "Write", .description = "", .input_schema = .{} },
        .{ .name = "Bash", .description = "", .input_schema = .{} },
    };
    const defs = try seatToolDefs(testing.allocator, &host, write_scope.toolsFor(.implementer));
    defer testing.allocator.free(defs);
    try testing.expectEqual(@as(usize, 3), defs.len);
    try testing.expectEqualStrings("Read", defs[0].name);
    try testing.expectEqualStrings("Write", defs[1].name);
    try testing.expectEqualStrings("Bash", defs[2].name);
}

test "metacodes driver: seat permission refuses to prompt and keeps the seat's roots" {
    var host = permission_mod.createContext(.bypass_permissions, testing.allocator);
    host.memdir_abs = "/home/u/.metacodes/memory";
    const dirs = [_][]const u8{"/state/teamwork/r1/seats/implementer-1"};
    const sandbox = write_scope.seatSandbox(null);
    const perm = seatPermission(&host, "/ws", "/home/u", &dirs, &sandbox);
    try testing.expectEqual(@import("../../types.zig").PermissionMode.accept_edits, perm.modeValue());
    try testing.expect(perm.no_interactive_prompt);
    try testing.expect(perm.ui_requester == null);
    try testing.expectEqualStrings("", perm.memdir_abs);
    try testing.expectEqualStrings("/ws", perm.match_ctx.cwd);
    try testing.expectEqual(@as(usize, 1), perm.match_ctx.additional_dirs.len);
}
