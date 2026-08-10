//! Per-Run production loader for an optional active project rule bundle.
//! Missing `active.json` preserves legacy behavior. Once an active pointer is
//! present, missing/invalid kernel configuration or any artifact drift fails
//! before the provider request and before tool side effects.

const std = @import("std");
const bundle = @import("project_rule_bundle.zig");
const runtime_gate = @import("project_rule_gate.zig");
const kernel = @import("../formal/project_harness_runtime.zig");
const protocol = @import("../tools/project_rule_gate.zig");
const observation = @import("../tools/observation.zig");
const journal_mod = @import("tool_observation_journal.zig");
const session_id_mod = @import("session_id.zig");
const project_harness_build_options = @import("project_harness_build_options");

/// This value is baked into the executable.  Production/library/test roots
/// compile it as false; only `eval:project-harness-shadow` compiles true.
/// Never replace this boundary with an environment variable or CLI option.
pub const artifact_actuation: observation.FormalActuation =
    if (project_harness_build_options.evaluation_shadow) .shadow else .enforced;

test "ordinary product and library roots compile project rules enforced" {
    try std.testing.expectEqual(observation.FormalActuation.enforced, artifact_actuation);
}

/// One product Run owns one durable observation writer and, when configured,
/// one re-attested project rule gate. Keeping both in one value prevents UI
/// adapters from loading an active rule without its evidence sink.
pub const RunControl = struct {
    allocator: std.mem.Allocator,
    journal: journal_mod.Journal,
    project_gate: ?*RunGate,

    pub fn init(
        allocator: std.mem.Allocator,
        session_dir: []const u8,
        session_id: session_id_mod.SessionId,
        project_root: []const u8,
        abort: ?*const @import("../util/abort.zig").AbortSignal,
    ) !*RunControl {
        const self = try allocator.create(RunControl);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .journal = try journal_mod.Journal.init(session_dir, session_id),
            .project_gate = null,
        };
        errdefer self.journal.deinit();
        const project_gate = RunGate.load(
            allocator,
            session_dir,
            project_root,
            abort,
            self.journal.sink(),
        ) catch |err| {
            // No provider request or tool action can occur before RunControl
            // returns. A gate configuration/artifact failure is therefore a
            // known pre-action abort, not an ambiguous crash window. Close it
            // durably so fixing the configuration does not require deleting a
            // poison lease; if the close itself fails, deinit keeps the lease.
            self.journal.finishRun("project_gate_load_failed") catch {};
            return err;
        };
        self.project_gate = project_gate;
        return self;
    }

    pub fn observer(self: *RunControl) observation.Sink {
        return self.journal.sink();
    }

    pub fn formalGate(self: *RunControl) ?protocol.Gate {
        return if (self.project_gate) |gate| gate.gate() else null;
    }

    pub fn requireDetachedIdle(
        self: *RunControl,
        background_jobs: usize,
        team_active: bool,
    ) !void {
        if (self.project_gate != null and (background_jobs != 0 or team_active))
            return error.ProjectRulesRequireDetachedWorkersIdle;
    }

    pub fn finishRun(self: *RunControl, stop_reason: []const u8) !void {
        try self.journal.finishRun(stop_reason);
    }

    pub fn deinit(self: *RunControl) void {
        const allocator = self.allocator;
        if (self.project_gate) |gate| gate.deinit();
        self.journal.deinit();
        allocator.destroy(self);
    }
};

pub const RunGate = struct {
    allocator: std.mem.Allocator,
    directory: []u8,
    active: bundle.LoadedActive,
    runtime: runtime_gate.RuntimeGate,

    pub fn load(
        allocator: std.mem.Allocator,
        session_dir: []const u8,
        project_root: []const u8,
        abort: ?*const @import("../util/abort.zig").AbortSignal,
        observation_sink: ?@import("../tools/observation.zig").Sink,
    ) !?*RunGate {
        const state_root = std.fs.path.dirname(session_dir) orelse return error.InvalidSessionDirectory;
        const directory = try std.fmt.allocPrint(allocator, "{s}/project-rules", .{state_root});
        errdefer allocator.free(directory);
        if (!bundle.hasActive(directory)) {
            allocator.free(directory);
            return null;
        }
        // A production formal decision without a durable host journal is not
        // an auditable control loop. Direct RuntimeGate construction remains
        // available to focused tests, but the product loader never creates an
        // active gate that can silently discard its verdict evidence.
        if (observation_sink == null) return error.ProjectObservationSinkMissing;
        const config = switch (kernel.loadConfigFromEnv()) {
            .configured => |value| value,
            .missing => return error.ProjectKernelConfigurationMissing,
            .invalid => return error.ProjectKernelConfigurationInvalid,
        };
        const project = bundle.projectIdentity(project_root);
        var active = (try bundle.loadVerifiedActive(
            allocator,
            directory,
            project,
            config,
            abort,
        )) orelse return error.ActivePointerDisappeared;
        errdefer active.deinit();
        const self = try allocator.create(RunGate);
        self.* = .{
            .allocator = allocator,
            .directory = directory,
            .active = active,
            .runtime = undefined,
        };
        self.runtime = .{
            .allocator = allocator,
            .active = &self.active,
            .config = config,
            .abort = abort,
            .actuation = artifact_actuation,
            .evidence_dir = session_dir,
            .observation_sink = observation_sink,
            .auto_exact_edit_recovery = true,
        };
        return self;
    }

    pub fn gate(self: *RunGate) protocol.Gate {
        return self.runtime.protocolGate();
    }

    pub fn deinit(self: *RunGate) void {
        const allocator = self.allocator;
        self.active.deinit();
        allocator.free(self.directory);
        allocator.destroy(self);
    }
};

test "production loader keeps an unconfigured project without active pointer unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const session = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/session",
        .{root_buffer[0..root_len]},
    );
    defer std.testing.allocator.free(session);
    const loaded = try RunGate.load(std.testing.allocator, session, root_buffer[0..root_len], null, null);
    try std.testing.expect(loaded == null);
}

test "RunControl keeps the returned journal sink address stable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const session_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/session", .{root});
    defer std.testing.allocator.free(session_dir);
    try @import("../util/fs.zig").mkdirParents(session_dir);
    const session = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;
    const control = try RunControl.init(std.testing.allocator, session_dir, session, root, null);
    const sink = control.observer();
    try std.testing.expect(sink.emit(.{ .dispatch_started = .{
        .id = "stable-sink",
        .requested_name = "Read",
        .dispatched_name = "Read",
        .origin = .authoritative,
        .agent_depth = 0,
        .input_bytes = 2,
        .input_sha256 = observation.sha256Hex("{}"),
    } }));
    try std.testing.expect(sink.emit(.{ .dispatch_finished = .{
        .id = "stable-sink",
        .requested_name = "Read",
        .dispatched_name = "Read",
        .origin = .authoritative,
        .agent_depth = 0,
        .outcome = .succeeded,
        .error_code = null,
        .elapsed_ms = 1,
        .result_present = true,
        .result_bytes = 2,
        .result_sha256 = observation.sha256Hex("ok"),
        .effect = null,
        .effect_valid = true,
    } }));
    try control.finishRun("end_turn");
    const binding = try control.journal.runBinding();
    control.deinit();
    var loaded = try journal_mod.loadRunDispatches(std.testing.allocator, session_dir, binding);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.dispatches.len);
}
