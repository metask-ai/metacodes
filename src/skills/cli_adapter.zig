//! CLI adapter for the single canonical Skill Runtime.
//!
//! Product-specific concerns live here: DynRegistry registration, slash/model
//! argument parsing, App policy projection, and the existing subagent runner.
//! Discovery, snapshot, validation, materialization, rendering, and policy
//! derivation remain owned by `skills/runtime`.

const std = @import("std");
const paths = @import("platform").paths;
const sync = @import("platform").sync;
const runtime = @import("runtime/root.zig");
const skill_projection = @import("skill.zig");
const ActiveSkillState = @import("active.zig").ActiveSkillState;
const ToolContext = @import("../tools/context.zig").ToolContext;
const PermissionContext = @import("../permission.zig").PermissionContext;
const session_id = @import("../core/session_id.zig");
const SessionId = session_id.SessionId;
const ToolDefinition = @import("../json.zig").ToolDefinition;
const DynRegistry = @import("../tools/dynamic.zig").DynRegistry;
const agent_tool = @import("../tools/agent.zig");
const subagent = @import("../core/subagent.zig");
const preload = @import("../agents/preload.zig");
const agent_loop = @import("../core/agent_loop.zig");
const project_activation = @import("../core/project_rule_activation.zig");
const writer_backend = @import("../core/writer_backend.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

const ActivationEntry = struct {
    activation: *runtime.activation.Activation,
    invocation_name: []const u8,
    projected: bool = false,
};

const ExecutionState = struct {
    base_frame: *runtime.policy_frame.PolicyFrame,
    activations: std.ArrayList(ActivationEntry) = .empty,
    projection: ?ActiveSkillState = null,
    permission_ctx: *PermissionContext,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    snapshot: ?*runtime.catalog.Snapshot = null,
    materializations: ?runtime.materialization.Manager = null,
    root_frame: ?*runtime.policy_frame.PolicyFrame = null,
    contexts_mutex: sync.Mutex = .{},
    contexts: std.AutoHashMap([24]u8, *ExecutionState),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Runtime {
        return .{
            .allocator = allocator,
            .io = io,
            .contexts = std.AutoHashMap([24]u8, *ExecutionState).init(allocator),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.clearAllContexts();
        if (self.root_frame) |frame| frame.release();
        if (self.materializations) |*manager| manager.deinitFinal();
        if (self.snapshot) |snapshot| snapshot.deinit();
        self.contexts.deinit();
        self.* = undefined;
    }

    pub fn loadDefault(
        self: *Runtime,
        cwd: []const u8,
        home: []const u8,
        projection: *skill_projection.SkillSet,
    ) !void {
        return self.loadDefaultWithExtraSources(cwd, home, "", &.{}, projection);
    }

    /// Product defaults plus Host-admitted plugin sources are resolved by one
    /// canonical catalog build. Plugins therefore cannot bypass normal Skill
    /// parsing, availability, activation, policy frames, or revision hashing.
    pub fn loadDefaultWithExtraSources(
        self: *Runtime,
        cwd: []const u8,
        home: []const u8,
        workspace_epoch: []const u8,
        extra_sources: []const runtime.catalog.Source,
        projection: *skill_projection.SkillSet,
    ) !void {
        const workspace_root = skill_projection.findRepoRoot(self.allocator, cwd) catch
            try self.allocator.dupe(u8, cwd);
        defer self.allocator.free(workspace_root);

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const defaults = try runtime.catalog.defaultSources(
            scratch.allocator(),
            workspace_root,
            home,
        );
        var combined: std.ArrayList(runtime.catalog.Source) = .empty;
        try combined.appendSlice(scratch.allocator(), defaults);
        try combined.appendSlice(scratch.allocator(), extra_sources);
        try self.loadSources(workspace_root, home, workspace_epoch, combined.items, projection);
    }

    pub fn loadSources(
        self: *Runtime,
        workspace_root: []const u8,
        workspace_home: []const u8,
        workspace_epoch: []const u8,
        sources: []const runtime.catalog.Source,
        projection: *skill_projection.SkillSet,
    ) !void {
        const scope_id = cliScopeId(workspace_root, workspace_home);
        const next_snapshot = try runtime.catalog.build(
            self.allocator,
            self.io,
            &scope_id,
            workspace_epoch,
            sources,
            .{},
        );
        errdefer next_snapshot.deinit();

        var next_materializations: ?runtime.materialization.Manager =
            runtime.materialization.Manager.initWithBorrowedIo(
                self.allocator,
                self.io,
                paths.tempDir(),
            ) catch |err| switch (err) {
                error.UnsupportedFilesystem => null,
                else => return err,
            };
        errdefer if (next_materializations) |*manager| manager.deinitFinal();
        try projection.replaceFromSnapshot(next_snapshot);

        self.clearAllContexts();
        if (self.root_frame) |frame| {
            frame.release();
            self.root_frame = null;
        }
        if (self.materializations) |*manager| manager.deinitFinal();
        if (self.snapshot) |snapshot| snapshot.deinit();
        self.snapshot = next_snapshot;
        self.materializations = next_materializations;
    }

    pub fn findRecord(self: *const Runtime, invocation_name: []const u8) ?*const runtime.catalog.SkillRecord {
        const snapshot = self.snapshot orelse return null;
        return snapshot.findByInvocation(invocation_name);
    }

    pub fn findIssue(
        self: *const Runtime,
        invocation_name: []const u8,
    ) ?*const runtime.catalog.Issue {
        const snapshot = self.snapshot orelse return null;
        for (snapshot.issues) |*issue| {
            const name = issue.invocation_name orelse continue;
            if (std.mem.eql(u8, name, invocation_name)) return issue;
        }
        return null;
    }

    pub fn hasModelInvocable(self: *const Runtime) bool {
        if (self.materializations == null) return false;
        const snapshot = self.snapshot orelse return false;
        return runtime.model_tool.hasModelInvocable(snapshot);
    }

    /// Patch the CLI-owned dynamic definition with the canonical schema plus
    /// immutable model-routing metadata. The exact Skill name is borrowed from
    /// this Runtime snapshot and therefore stays stable for the Session.
    pub fn applyModelToolSchema(self: *const Runtime, definitions: []ToolDefinition) bool {
        const snapshot = self.snapshot orelse return false;
        for (definitions) |*definition| {
            if (!std.mem.eql(u8, definition.name, runtime.model_tool.TOOL_NAME))
                continue;
            definition.input_schema.prop_specs = &runtime.model_tool.INPUT_PROPERTIES;
            definition.input_schema.properties = null;
            definition.input_schema.required = runtime.model_tool.REQUIRED_FIELDS;
            definition.model_activation = runtime.model_tool.modelActivation(snapshot);
            return true;
        }
        return false;
    }

    pub fn activate(
        self: *Runtime,
        ctx: *const ToolContext,
        invocation_name: []const u8,
        values: []const []const u8,
        activation_context: runtime.activation.Context,
    ) !*runtime.activation.Activation {
        self.contexts_mutex.lock();
        defer self.contexts_mutex.unlock();

        const snapshot = self.snapshot orelse return error.SkillUnavailable;
        const materializations = if (self.materializations) |*manager|
            manager
        else
            return error.SkillUnavailable;
        const record = snapshot.findByInvocation(invocation_name) orelse
            return error.SkillNotFound;
        const abort = ctx.abort orelse return error.SkillUnavailable;
        const state = try self.ensureContextLocked(ctx);
        const parent = currentFrameLocked(state);
        const shell_policy = shellPolicy(ctx);
        var plan = try runtime.activation.prepareValues(
            self.allocator,
            snapshot,
            &snapshot.revision,
            &record.skill_id,
            values,
            .{
                .context = activation_context,
                .shell_policy = shell_policy,
                .model_override_capability = .allowed,
            },
        );
        defer plan.deinit();

        const activation = try self.allocator.create(runtime.activation.Activation);
        errdefer self.allocator.destroy(activation);
        activation.* = try runtime.activation.activate(self.allocator, &plan, .{
            .materializations = materializations,
            .parent_frame = parent,
            .abort = abort,
            .project_dir = ctx.project_dir,
            .session_id = ctx.session_id,
            .sandbox = ctx.sandbox,
            .cwd_abs = ctx.cwd_abs,
            .home_dir = ctx.home_dir,
            .additional_dirs = ctx.additional_dirs,
            .parent_agent_depth = ctx.agent_depth,
        });
        errdefer activation.deinit() catch {};
        try state.activations.append(self.allocator, .{
            .activation = activation,
            .invocation_name = record.invocation_name,
        });
        return activation;
    }

    pub fn currentPolicyFrame(self: *Runtime) ?*runtime.policy_frame.PolicyFrame {
        self.contexts_mutex.lock();
        defer self.contexts_mutex.unlock();
        var iterator = self.contexts.valueIterator();
        const only = iterator.next() orelse return null;
        if (iterator.next() != null) return null;
        if (only.*.activations.items.len == 0) return null;
        return currentFrameLocked(only.*);
    }

    pub fn currentPolicyFrameFor(
        self: *Runtime,
        agent_ident: SessionId,
    ) ?*runtime.policy_frame.PolicyFrame {
        self.contexts_mutex.lock();
        defer self.contexts_mutex.unlock();
        const state = self.contexts.get(agent_ident.bytes) orelse return null;
        if (state.activations.items.len == 0) return null;
        return currentFrameLocked(state);
    }

    pub fn projectCurrent(
        self: *Runtime,
        agent_ident: SessionId,
        permission_ctx: *PermissionContext,
    ) !void {
        self.contexts_mutex.lock();
        defer self.contexts_mutex.unlock();
        const state = self.contexts.get(agent_ident.bytes) orelse
            return error.SkillPolicyUnavailable;
        if (state.permission_ctx != permission_ctx)
            return error.SkillPolicyUnavailable;
        if (state.activations.items.len == 0)
            return error.SkillPolicyUnavailable;
        const last = &state.activations.items[state.activations.items.len - 1];
        last.projected = true;
        refreshProjectionLocked(state);
    }

    pub fn finishActivation(
        self: *Runtime,
        agent_ident: SessionId,
        expected: *runtime.activation.Activation,
    ) !void {
        self.contexts_mutex.lock();
        defer self.contexts_mutex.unlock();
        const state = self.contexts.get(agent_ident.bytes) orelse
            return error.SkillPolicyUnavailable;
        if (state.activations.items.len == 0)
            return error.SkillPolicyUnavailable;
        const last = state.activations.items[state.activations.items.len - 1];
        if (last.activation != expected) return error.SkillPolicyUnavailable;
        _ = state.activations.pop();
        if (last.projected) refreshProjectionLocked(state);
        const cleanup_result = last.activation.deinit();
        self.allocator.destroy(last.activation);
        cleanup_result catch return error.CoreError;
    }

    fn rollbackActivation(
        self: *Runtime,
        agent_ident: SessionId,
        expected: *runtime.activation.Activation,
    ) void {
        self.finishActivation(agent_ident, expected) catch {};
    }

    fn registerChildContext(
        self: *Runtime,
        agent_ident: SessionId,
        base_frame: *runtime.policy_frame.PolicyFrame,
        permission_ctx: *PermissionContext,
    ) !void {
        self.contexts_mutex.lock();
        defer self.contexts_mutex.unlock();
        if (self.contexts.contains(agent_ident.bytes))
            return error.SkillPolicyUnavailable;
        try base_frame.retain();
        errdefer base_frame.release();
        const state = try self.allocator.create(ExecutionState);
        errdefer self.allocator.destroy(state);
        state.* = .{
            .base_frame = base_frame,
            .permission_ctx = permission_ctx,
        };
        try self.contexts.put(agent_ident.bytes, state);
    }

    fn unregisterContextStrict(
        self: *Runtime,
        agent_ident: SessionId,
    ) !void {
        self.contexts_mutex.lock();
        defer self.contexts_mutex.unlock();
        const removed = self.contexts.fetchRemove(agent_ident.bytes) orelse
            return;
        if (self.destroyStateLocked(removed.value))
            return error.CoreError;
    }

    pub fn clearContext(self: *Runtime, agent_ident: SessionId) void {
        self.unregisterContextStrict(agent_ident) catch {};
    }

    fn clearAllContexts(self: *Runtime) void {
        self.contexts_mutex.lock();
        defer self.contexts_mutex.unlock();
        var iterator = self.contexts.valueIterator();
        while (iterator.next()) |state| _ = self.destroyStateLocked(state.*);
        self.contexts.clearRetainingCapacity();
    }

    fn destroyStateLocked(self: *Runtime, state: *ExecutionState) bool {
        var cleanup_failed = false;
        if (state.projection) |*projection| {
            if (state.permission_ctx.active_skill == projection)
                state.permission_ctx.active_skill = null;
            projection.deinit();
            state.projection = null;
        }
        var index = state.activations.items.len;
        while (index > 0) {
            index -= 1;
            const activation = state.activations.items[index].activation;
            activation.deinit() catch {
                cleanup_failed = true;
            };
            self.allocator.destroy(activation);
        }
        state.activations.deinit(self.allocator);
        state.base_frame.release();
        self.allocator.destroy(state);
        return cleanup_failed;
    }

    fn ensureContextLocked(self: *Runtime, ctx: *const ToolContext) !*ExecutionState {
        if (self.contexts.get(ctx.agent_ident.bytes)) |state| {
            if (ctx.permission_ctx) |permission| {
                if (state.permission_ctx != permission)
                    return error.SkillPolicyUnavailable;
            }
            return state;
        }
        // A generic subagent has no adapter-owned terminal callback through
        // which this Runtime could release a persistent inline activation.
        // Only Runtime-managed fork children are pre-registered above. Refuse
        // any other child instead of retaining a stack-local PermissionContext
        // past its lifetime or silently widening policy at child terminal.
        if (ctx.agent_depth != 0) return error.SkillUnavailable;
        const permission = ctx.permission_ctx orelse
            return error.SkillPolicyUnavailable;
        const root = try self.rootFrameLocked(ctx);
        try root.retain();
        errdefer root.release();
        const state = try self.allocator.create(ExecutionState);
        errdefer self.allocator.destroy(state);
        state.* = .{
            .base_frame = root,
            .permission_ctx = permission,
        };
        try self.contexts.put(ctx.agent_ident.bytes, state);
        return state;
    }

    fn rootFrameLocked(
        self: *Runtime,
        ctx: *const ToolContext,
    ) !*runtime.policy_frame.PolicyFrame {
        if (self.root_frame) |frame| return frame;

        const definitions = ctx.tool_defs orelse &.{};
        const tool_names = try self.allocator.alloc([]const u8, definitions.len);
        defer self.allocator.free(tool_names);
        for (definitions, tool_names) |definition, *name| name.* = definition.name;

        const permission_mode = if (ctx.permission_ctx) |permission|
            permission.mode.load(.acquire)
        else
            .default;
        const match_context = if (ctx.permission_ctx) |permission|
            permission.match_ctx
        else
            @import("../permission/rule_spec.zig").MatchContext{
                .cwd = ctx.cwd_abs,
                .project_root = ctx.project_dir,
                .home = ctx.home_dir,
                .additional_dirs = ctx.additional_dirs,
                .alloc = self.allocator,
            };
        const frame = try runtime.policy_frame.PolicyFrame.createRoot(
            self.allocator,
            tool_names,
            shellPolicy(ctx),
            permission_mode,
            match_context,
        );
        self.root_frame = frame;
        return frame;
    }
};

fn currentFrameLocked(state: *const ExecutionState) *runtime.policy_frame.PolicyFrame {
    if (state.activations.items.len == 0) return state.base_frame;
    return state.activations.items[state.activations.items.len - 1].activation.frame;
}

fn refreshProjectionLocked(state: *ExecutionState) void {
    if (state.projection) |*projection| {
        if (state.permission_ctx.active_skill == projection)
            state.permission_ctx.active_skill = null;
        projection.deinit();
        state.projection = null;
    }
    var index = state.activations.items.len;
    while (index > 0) {
        index -= 1;
        const entry = state.activations.items[index];
        if (!entry.projected) continue;
        state.projection = ActiveSkillState.borrowFromPolicyFrame(
            entry.invocation_name,
            entry.activation.frame,
        );
        state.permission_ctx.active_skill = &state.projection.?;
        return;
    }
}

pub fn registerModelTool(registry: *DynRegistry, skill_runtime: *Runtime) !void {
    if (!skill_runtime.hasModelInvocable())
        return error.SkillUnavailable;
    const snapshot = skill_runtime.snapshot orelse return error.SkillUnavailable;
    const description = try runtime.model_tool.buildDescription(
        skill_runtime.allocator,
        snapshot,
    );
    defer skill_runtime.allocator.free(description);
    try registry.register(
        runtime.model_tool.TOOL_NAME,
        description,
        runtime.model_tool.REQUIRED_FIELDS,
        executeModelTool,
        @ptrCast(skill_runtime),
        false,
    );
}

/// DynRegistry's legacy required-fields registration shape cannot describe
/// array properties. Patch only the adapter-owned model surface after App
/// assembles final definitions; typed execution still dispatches through the
/// registry.
pub fn applyModelToolSchema(definitions: []ToolDefinition) bool {
    for (definitions) |*definition| {
        if (!std.mem.eql(u8, definition.name, runtime.model_tool.TOOL_NAME))
            continue;
        definition.input_schema.prop_specs =
            &runtime.model_tool.INPUT_PROPERTIES;
        definition.input_schema.properties = null;
        definition.input_schema.required =
            runtime.model_tool.REQUIRED_FIELDS;
        return true;
    }
    return false;
}

pub const SlashDisposition = enum {
    handled,
    unknown_command,
    not_a_command,
};

pub const SlashSyntax = union(enum) {
    command: []const u8,
    not_a_command,
};

pub fn parseSlashSyntax(rest: []const u8) SlashSyntax {
    var head_end: usize = 0;
    while (head_end < rest.len and rest[head_end] != ' ' and rest[head_end] != '\t') : (head_end += 1) {}
    const head = rest[0..head_end];
    if (head.len == 0 or !runtime.catalog.validInvocationName(head))
        return .not_a_command;
    return .{ .command = head };
}

/// Product slash adapter. Built-in commands are consumed before this function.
/// Invalid invocation syntax is not a command and must remain ordinary user
/// text; a valid but missing invocation is an unknown command.
pub fn handleSlash(
    app: anytype,
    allocator: std.mem.Allocator,
    rest: []const u8,
) !SlashDisposition {
    const head = switch (parseSlashSyntax(rest)) {
        .command => |value| value,
        .not_a_command => return .not_a_command,
    };
    const record = app.skill_runtime.findRecord(head) orelse {
        if (app.skill_runtime.findIssue(head)) |issue| {
            std.debug.print(
                "\x1b[31m/{s}: Skill unavailable ({s})\x1b[0m\n",
                .{ head, @tagName(issue.code) },
            );
            return .handled;
        }
        return .unknown_command;
    };
    const values = parseSlashValues(
        allocator,
        std.mem.trim(u8, rest[head.len..], " \t"),
    ) catch |err| {
        std.debug.print(
            "\x1b[31m/{s}: invalid Skill arguments: {s}\x1b[0m\n",
            .{ head, @errorName(err) },
        );
        return .handled;
    };
    defer freeStrings(allocator, values);

    app.clearActiveSkill();
    var tool_context = ToolContext{
        .allocator = allocator,
        .abort = &app.abort,
        .read_state = &app.read_state,
        .permission_ctx = &app.permission_ctx,
        .provider = app.provider(),
        .tool_defs = app.tool_defs,
        .dyn_registry = &app.dyn_registry,
        .host_services = app.hostServices(),
        .agent_ident = app.session_id,
        .project_dir = app.project_dir_or_empty(),
        .session_id = app.session_id.asSlice(),
        .sandbox = app.sandboxPtr(),
        .cwd_abs = app.cwdAbs(),
        .additional_dirs = app.additionalDirs(),
        .home_dir = app.homeDir(),
        .agents = &app.agents,
        .parent_model = app.activeModel(),
        .skills = &app.skills,
        .api_client = app.anthropicClientOrNull(),
    };
    const activation = app.skill_runtime.activate(
        &tool_context,
        head,
        values,
        .external_run_root,
    ) catch |err| {
        std.debug.print(
            "\x1b[31m/{s}: skill activation failed: {s}\x1b[0m\n",
            .{ head, @errorName(err) },
        );
        return .handled;
    };
    var activation_live = true;
    defer if (activation_live)
        app.skill_runtime.rollbackActivation(app.session_id, activation);

    const raw_arguments = std.mem.trim(u8, rest[head.len..], " \t");
    const user_message = if (raw_arguments.len == 0)
        try std.fmt.allocPrint(allocator, "/{s}", .{head})
    else
        try std.fmt.allocPrint(allocator, "/{s} {s}", .{ head, raw_arguments });
    defer allocator.free(user_message);

    if (record.definition.context == .fork) {
        const final_text = executeFork(
            &app.skill_runtime,
            &tool_context,
            activation,
        ) catch |err| {
            std.debug.print(
                "\x1b[31m/{s}: fork execution failed: {s}\x1b[0m\n",
                .{ head, @errorName(err) },
            );
            return .handled;
        };
        defer allocator.free(final_text);
        app.skill_runtime.finishActivation(
            app.session_id,
            activation,
        ) catch |err| {
            std.debug.print(
                "\x1b[31m/{s}: activation cleanup failed: {s}\x1b[0m\n",
                .{ head, @errorName(err) },
            );
            activation_live = false;
            return .handled;
        };
        activation_live = false;

        try app.conversation.appendText(.user, user_message);
        if (final_text.len != 0)
            try app.conversation.appendText(.assistant, final_text);
        std.debug.print("\x1b[36m{s}\x1b[0m\n", .{final_text});
        app.persistTranscript();
        return .handled;
    }

    app.activateSkill(head, activation.frame.effectiveTools(), &.{}) catch |err| {
        std.debug.print(
            "\x1b[31m/{s}: policy projection failed: {s}\x1b[0m\n",
            .{ head, @errorName(err) },
        );
        return .handled;
    };
    activation_live = false;
    errdefer app.clearActiveSkill();

    const skill_result = try runtime.model_tool.formatResult(
        allocator,
        record.definition.name,
        activation.rendered_body,
        false,
    );
    defer allocator.free(skill_result);

    try app.conversation.appendText(.user, user_message);
    try app.conversation.appendText(.user, skill_result);
    std.debug.print("\x1b[36m{s}\x1b[0m\n", .{skill_result});

    var backend = writer_backend.WriterBackend{
        .sink_ctx = undefined,
        .sink = debugSink,
        .colorize = true,
        .verbose = app.config.verbose,
        .show_retry = true,
        .usage_acc = &app.usage,
    };
    const ui_backend = backend.backend();
    const run_control: ?*project_activation.RunControl = if (app.sessionDir()) |dir|
        try project_activation.RunControl.init(
            allocator,
            dir,
            app.session_id,
            if (app.project_dir_or_empty().len > 0) app.project_dir_or_empty() else app.cwdAbs(),
            &app.abort,
        )
    else
        null;
    defer if (run_control) |control| control.deinit();
    if (run_control) |control| control.requireDetachedIdle(
        (if (app.jobs) |*registry| registry.runningCount() else 0) +|
            (if (app.agent_jobs) |*registry| registry.runningCount() else 0),
        app.swarm.hasTeam(),
    ) catch |err| {
        try control.finishRun(@errorName(err));
        return err;
    };
    // U11(issue #3):字段装配走 canonical session_service.buildRunOptions。此前本路径
    // 手抄 Options 漏了 agents/skills_set/mcp_sessions/cron_registry/file_change_journal/
    // parent_model 等 7 字段——skill 触发的 run 里模型能力被静默削弱;收敛后仅补
    // run_control 三件套(本路径专属)。
    var run_opts = @import("../session_service.zig").buildRunOptions(app, null);
    run_opts.tool_observer = if (run_control) |control| control.observer() else null;
    run_opts.execution_boundary = if (run_control) |control| control.executionBoundary() else null;
    run_opts.project_rule_gate = if (run_control) |control| control.formalGate() else null;
    const result = agent_loop.run(
        &app.conversation,
        app.provider(),
        app.tool_defs,
        &app.permission_ctx,
        run_opts,
        &ui_backend,
        allocator,
    ) catch |err| {
        if (run_control) |control| try control.finishRun(@errorName(err));
        std.debug.print("\x1b[31mError after /{s}: {s}\x1b[0m\n", .{ head, @errorName(err) });
        app.clearPendingModelSwitchCompact();
        return .handled;
    };
    if (run_control) |control| try control.finishRun(@tagName(result.stop_reason));
    app.clearPendingModelSwitchCompact();
    app.persistTranscript();
    if (result.stop_reason == .aborted) app.abort.resetForTesting();
    return .handled;
}

fn debugSink(_: *anyopaque, bytes: []const u8) void {
    std.debug.print("{s}", .{bytes});
}

fn executeModelTool(
    ctx: *const ToolContext,
    encoded: []const u8,
    raw_context: ?*anyopaque,
) anyerror![]u8 {
    const self: *Runtime = @ptrCast(@alignCast(raw_context orelse return error.SkillUnavailable));
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    const invocation = try runtime.model_tool.parseInvocation(
        scratch.allocator(),
        encoded,
    );
    const activation = try self.activate(
        ctx,
        invocation.name,
        invocation.values,
        .model_tool,
    );
    var activation_live = true;
    errdefer if (activation_live)
        self.rollbackActivation(ctx.agent_ident, activation);
    const record = self.findRecord(invocation.name) orelse
        return error.SkillNotFound;

    if (record.definition.context == .fork) {
        const final_text = try executeFork(self, ctx, activation);
        defer ctx.allocator.free(final_text);
        try self.finishActivation(ctx.agent_ident, activation);
        activation_live = false;
        return runtime.model_tool.formatResult(
            ctx.allocator,
            record.definition.name,
            final_text,
            true,
        );
    }
    const permission = ctx.permission_ctx orelse
        return error.SkillPolicyUnavailable;
    try self.projectCurrent(ctx.agent_ident, permission);
    const output = try runtime.model_tool.formatResult(
        ctx.allocator,
        record.definition.name,
        activation.rendered_body,
        false,
    );
    activation_live = false;
    return output;
}

fn executeFork(
    self: *Runtime,
    ctx: *const ToolContext,
    activation: *const runtime.activation.Activation,
) ![]u8 {
    const api_client = ctx.api_client orelse return error.ForkUnavailable;
    const tool_defs = ctx.tool_defs orelse return error.ForkUnavailable;
    const permission = ctx.permission_ctx orelse return error.ForkUnavailable;
    if (ctx.agent_depth >= agent_tool.MAX_AGENT_DEPTH) return error.AgentDepthExceeded;

    var system_prompt: []const u8 = "You are a subagent. Complete the task and return a concise summary.\n";
    var owned_prompt: ?[]u8 = null;
    defer if (owned_prompt) |prompt| ctx.allocator.free(prompt);
    if (ctx.agents) |agents| {
        if (agents.find("general-purpose")) |definition| {
            owned_prompt = try preload.buildSubagentContext(ctx.allocator, definition, .{
                .project_dir = ctx.project_dir,
                .parent_model = ctx.parent_model,
                .session_id = ctx.session_id,
                .skills = ctx.skills,
                .skip_codebase_context = preload.shouldSkipCodebaseContext(definition.name),
                .abort = ctx.abort,
                .sandbox = ctx.sandbox,
                .cwd_abs = ctx.cwd_abs,
                .home_dir = ctx.home_dir,
                .additional_dirs = ctx.additional_dirs,
            });
            system_prompt = owned_prompt.?;
        }
    }

    // skill.model 与 Task 同语义:档位名查当前 provider 档位表(未配置 → inherit),
    // 显式模型名透传。档位 effort 此路径暂不消费(fork 子跑道无 effort override 通道)。
    const model_override = switch (activation.model_selection) {
        .inherit_parent => null,
        .override => |model| agent_tool.resolveModelSelection(ctx.model_tiers, model, null).model,
    };
    var child_permission = permission.scopedDerive(null);
    child_permission.active_skill = null;
    const child_ident = session_id.gen();
    try self.registerChildContext(
        child_ident,
        activation.frame,
        &child_permission,
    );
    const result = subagent.spawnAgent(
        ctx.allocator,
        ctx.provider orelse api_client.provider(),
        api_client,
        tool_defs,
        &child_permission,
        ctx.abort,
        activation.rendered_body,
        .{
            .system_prompt = system_prompt,
            .agent_depth = ctx.agent_depth + 1,
            .dyn_registry = ctx.dyn_registry,
            .model_override = model_override,
            .host_services = null,
            .project_dir = ctx.project_dir,
            .execution_policy = activation.frame.executionPolicy(),
            .agent_ident = child_ident,
        },
    ) catch |run_error| {
        self.unregisterContextStrict(child_ident) catch
            return error.CoreError;
        return run_error;
    };
    defer result.deinit();
    const output = ctx.allocator.dupe(u8, result.final_text) catch |copy_error| {
        self.unregisterContextStrict(child_ident) catch
            return error.CoreError;
        return copy_error;
    };
    self.unregisterContextStrict(child_ident) catch {
        ctx.allocator.free(output);
        return error.CoreError;
    };
    return output;
}

fn shellPolicy(ctx: *const ToolContext) @import("../core/workspace_policy.zig").ShellPolicy {
    if (ctx.disable_shell_execution) return .disabled;
    if (ctx.sandbox) |sandbox| if (sandbox.enabled) return .sandboxed;
    return .unrestricted;
}

fn cliScopeId(workspace_root: []const u8, workspace_home: []const u8) [64]u8 {
    var hash = Sha256.init(.{});
    hash.update("metacodes-cli-scope-v1");
    hashField(&hash, workspace_root);
    hashField(&hash, workspace_home);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashField(hash: *Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .big);
    hash.update(&length);
    hash.update(value);
}

pub fn parseSlashValues(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    if (raw.len > runtime.activation.MAX_ARGUMENT_JSON_BYTES)
        return error.ResourceLimit;
    var values: std.ArrayList([]const u8) = .empty;
    errdefer freeArrayList(allocator, &values);
    var index: usize = 0;
    while (index < raw.len) {
        while (index < raw.len and (raw[index] == ' ' or raw[index] == '\t')) : (index += 1) {}
        if (index == raw.len) break;
        if (values.items.len == runtime.activation.MAX_ARGUMENT_VALUES)
            return error.InvalidArguments;
        if (raw[index] == '"') {
            index += 1;
            const start = index;
            while (index < raw.len and raw[index] != '"') : (index += 1) {}
            if (index == raw.len) return error.InvalidArguments;
            try appendOwned(allocator, &values, raw[start..index]);
            index += 1;
        } else {
            const start = index;
            while (index < raw.len and raw[index] != ' ' and raw[index] != '\t') : (index += 1) {}
            try appendOwned(allocator, &values, raw[start..index]);
        }
    }
    return values.toOwnedSlice(allocator);
}

fn appendOwned(
    allocator: std.mem.Allocator,
    values: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try values.append(allocator, owned);
}

fn freeArrayList(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8)) void {
    for (values.items) |value| allocator.free(value);
    values.deinit(allocator);
}

fn freeStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}
