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
const overrides_mod = @import("overrides.zig");
const ActiveSkillState = @import("active.zig").ActiveSkillState;
const ToolContext = @import("../tools/context.zig").ToolContext;
const PermissionContext = @import("../permission.zig").PermissionContext;
const session_id = @import("../core/session_id.zig");
const SessionId = session_id.SessionId;
const ToolDefinition = @import("../json.zig").ToolDefinition;
const DynRegistry = @import("../tools/dynamic.zig").DynRegistry;
const agent_tool = @import("../tools/agent.zig");
const subagent = @import("../core/subagent.zig");
const sealed_provider = @import("sealed/provider.zig");
const sealed_pin = @import("sealed/pin.zig");
const preload = @import("../agents/preload.zig");
const tool_common = @import("../tools/common.zig");

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
    /// `skillOverrides` (owned by the App, internally synchronized). Set once
    /// before the Runtime is shared; null applies no overrides.
    overrides: ?*overrides_mod.Overrides = null,

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
        state_root: []const u8,
        projection: *skill_projection.SkillSet,
    ) !void {
        return self.loadDefaultWithExtraSources(cwd, home, state_root, &.{}, "", &.{}, projection);
    }

    /// Product defaults plus Host-admitted plugin sources are resolved by one
    /// canonical catalog build. Plugins therefore cannot bypass normal Skill
    /// parsing, availability, activation, policy frames, or revision hashing.
    pub fn loadDefaultWithExtraSources(
        self: *Runtime,
        cwd: []const u8,
        home: []const u8,
        state_root: []const u8,
        additional_dirs: []const []const u8,
        workspace_epoch: []const u8,
        extra_sources: []const runtime.catalog.Source,
        projection: *skill_projection.SkillSet,
    ) !void {
        const workspace_root = skill_projection.findRepoRoot(self.allocator, cwd) catch
            try self.allocator.dupe(u8, cwd);
        defer self.allocator.free(workspace_root);

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const defaults = try runtime.catalog.defaultSources(scratch.allocator(), .{
            .cwd = cwd,
            .workspace_root = workspace_root,
            .home = home,
            .state_root = state_root,
            .codex_home = paths.codexHomeEnv() orelse "",
            .additional_dirs = additional_dirs,
        });
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
        const log = @import("../util/log.zig");
        for (next_snapshot.skills) |record| {
            const definition = &record.definition;
            if (definition.warnings.contains(.blank_name)) log.warn(
                "skill",
                "/{s}: SKILL.md has a blank `name`; the directory name stands in (see /skills)",
                .{record.invocation_name},
            );
            switch (definition.description_source) {
                .frontmatter => {},
                .body_first_line, .missing => log.warn(
                    "skill",
                    "/{s}: SKILL.md {s}; listings use {s} (see /skills)",
                    .{
                        record.invocation_name,
                        if (definition.warnings.contains(.blank_description)) "has a blank `description`" else "has no `description`",
                        if (definition.description_source == .missing) "nothing" else "its first line",
                    },
                ),
            }
        }

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

    /// A Skill is invocable when the model may call it and its files are
    /// reachable: a compat Skill references its live directory, a snapshot
    /// Skill needs the materialization manager.
    pub fn hasModelInvocable(self: *const Runtime) bool {
        const snapshot = self.snapshot orelse return false;
        for (snapshot.skills) |record| {
            if (record.definition.disable_model_invocation) continue;
            if (record.live_dir != null or self.materializations != null) return true;
        }
        return false;
    }

    /// Patch the CLI-owned dynamic definition with the canonical schema plus
    /// immutable model-routing metadata. The exact Skill name is borrowed from
    /// this Runtime snapshot and therefore stays stable for the Session.
    pub fn applyModelToolSchema(self: *const Runtime, definitions: []ToolDefinition) bool {
        const snapshot = self.snapshot orelse return false;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const listings = self.modelListings(scratch.allocator()) catch null;
        for (definitions) |*definition| {
            if (!std.mem.eql(u8, definition.name, runtime.model_tool.TOOL_NAME))
                continue;
            definition.input_schema.prop_specs = &runtime.model_tool.INPUT_PROPERTIES;
            definition.input_schema.properties = null;
            definition.input_schema.required = runtime.model_tool.REQUIRED_FIELDS;
            definition.model_activation = runtime.model_tool.modelActivationWithListing(snapshot, .all, listings);
            return true;
        }
        return false;
    }

    /// The effective `skillOverrides` state of `invocation_name`.
    pub fn overrideState(self: *const Runtime, invocation_name: []const u8) overrides_mod.State {
        const overrides = self.overrides orelse return .on;
        return overrides.stateOf(invocation_name);
    }

    /// Per-Skill model listing under `skillOverrides`, aligned with the
    /// snapshot's records; null when no overrides apply.
    pub fn modelListings(self: *const Runtime, allocator: std.mem.Allocator) !?[]runtime.model_tool.Listing {
        const overrides = self.overrides orelse return null;
        const snapshot = self.snapshot orelse return null;
        const names = try allocator.alloc([]const u8, snapshot.skills.len);
        defer allocator.free(names);
        for (snapshot.skills, names) |record, *name| name.* = record.invocation_name;
        const states = try allocator.alloc(overrides_mod.State, snapshot.skills.len);
        defer allocator.free(states);
        overrides.statesOf(names, states);
        const listings = try allocator.alloc(runtime.model_tool.Listing, snapshot.skills.len);
        for (states, listings) |state, *listing| listing.* = state.listing();
        return listings;
    }

    /// The Skill tool description for the current `skillOverrides`.
    pub fn buildModelToolDescription(self: *const Runtime, allocator: std.mem.Allocator) ![]u8 {
        const snapshot = self.snapshot orelse return error.SkillUnavailable;
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const listings = try self.modelListings(scratch.allocator());
        return runtime.model_tool.buildDescriptionWithListing(allocator, snapshot, .all, listings);
    }

    /// Bring the Skill tool in `definitions` up to date after a
    /// `skillOverrides` change: its description (allocated from
    /// `allocator`, which must outlive `definitions`) and its required-first
    /// route. Returns false when `definitions` has no Skill tool.
    pub fn refreshModelTool(
        self: *const Runtime,
        definitions: []ToolDefinition,
        allocator: std.mem.Allocator,
    ) !bool {
        for (definitions) |*definition| {
            if (!std.mem.eql(u8, definition.name, runtime.model_tool.TOOL_NAME))
                continue;
            definition.description = try self.buildModelToolDescription(allocator);
            return self.applyModelToolSchema(definitions);
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
        const materializations: ?*runtime.materialization.Manager = if (self.materializations) |*manager|
            manager
        else
            null;
        const record = snapshot.findByInvocation(invocation_name) orelse
            return error.SkillNotFound;
        if (record.live_dir == null and materializations == null) return error.SkillUnavailable;
        const override = self.overrideState(record.invocation_name);
        switch (activation_context) {
            .model_tool => if (!override.modelInvocable()) return error.SkillDisabled,
            .external_run_root => if (!override.userInvocable()) return error.SkillDisabled,
        }
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
                .agent_profiles = .supported,
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

        // The frame records the mode decisions run under (never one the settings disable).
        const permission_mode = if (ctx.permission_ctx) |permission|
            permission.effectiveMode()
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

/// Register the model-facing Skill tool. It is registered whenever a Skill
/// may be model-invoked by its definition, so a `skillOverrides` change in
/// the Session changes its description, never the tool set.
pub fn registerModelTool(registry: *DynRegistry, skill_runtime: *Runtime) !void {
    if (!skill_runtime.hasModelInvocable())
        return error.SkillUnavailable;
    const description = try skill_runtime.buildModelToolDescription(skill_runtime.allocator);
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
    /// The Skill exists but `skillOverrides` turns it off: nothing ran.
    disabled,
    /// The Skill is active and its invocation is in the conversation: the
    /// host runs the model turn through its own (interactive) turn path, as
    /// it runs any prompt, then the activation ends with the next message.
    run,
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
    // The CLI catalog uses the compat grammar (a superset of the canonical one),
    // so `/地址库` reaches its Skill.
    if (head.len == 0 or !runtime.catalog.validCompatInvocationName(head))
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
    if (!app.skill_runtime.overrideState(record.invocation_name).userInvocable())
        return .disabled;
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
        .state_root = app.stateRoot(),
        .agents = &app.agents,
        .parent_model = app.activeModel(),
        .skills = &app.skills,
        .api_client = app.anthropicClientOrNull(),
        .preview = app.config.preview.features(),
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
        const fork = executeFork(
            &app.skill_runtime,
            &tool_context,
            record,
            activation,
            values,
        ) catch |err| {
            std.debug.print(
                "\x1b[31m/{s}: fork execution failed: {s}\x1b[0m\n",
                .{ head, @errorName(err) },
            );
            return .handled;
        };
        const final_text = fork.text;
        defer allocator.free(final_text);
        if (fork.refused_mode) |refused| std.debug.print(
            "\x1b[33m/{s}: {s}\x1b[0m\n",
            .{ head, agent_tool.modeNotice(refused) },
        );
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

    const skill_result = try formatSkillResult(
        allocator,
        record.definition.name,
        activation,
        activation.rendered_body,
        false,
    );
    defer allocator.free(skill_result);

    // The rendered Skill body is for the model; the user's scrollback shows
    // the invocation and the reply, as for any prompt (Claude Code).
    try app.conversation.appendText(.user, user_message);
    try app.conversation.appendHostText(skill_result);
    return .run;
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
    if (self.findRecord(invocation.name) != null and
        !self.overrideState(invocation.name).modelInvocable())
    {
        // Claude Code's refusal, word for word.
        tool_common.setErrorDetail(ctx.error_detail, ctx.allocator, "Skill {s} is disabled for model invocation in skillOverrides settings", .{invocation.name});
        return error.SkillDisabled;
    }
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
        const fork = try executeFork(self, ctx, record, activation, invocation.values);
        defer ctx.allocator.free(fork.text);
        try self.finishActivation(ctx.agent_ident, activation);
        activation_live = false;
        // A refused permissionMode leads the result, so the parent learns the
        // fork ran as default rather than in the mode the agent asks for.
        const noticed: ?[]u8 = if (fork.refused_mode) |refused|
            try std.fmt.allocPrint(ctx.allocator, "[{s}]\n\n{s}", .{ agent_tool.modeNotice(refused), fork.text })
        else
            null;
        defer if (noticed) |text| ctx.allocator.free(text);
        return formatSkillResult(
            ctx.allocator,
            record.definition.name,
            activation,
            noticed orelse fork.text,
            true,
        );
    }
    const permission = ctx.permission_ctx orelse
        return error.SkillPolicyUnavailable;
    try self.projectCurrent(ctx.agent_ident, permission);
    const output = try formatSkillResult(
        ctx.allocator,
        record.definition.name,
        activation,
        activation.rendered_body,
        false,
    );
    activation_live = false;
    return output;
}

/// Skill tool / slash result: the rendered instructions preceded by the
/// directory their relative paths resolve against. Claude Code and Codex both
/// give the model this location (Codex skills reference `scripts/` and
/// `references/` relative to SKILL.md); the body alone cannot be followed.
fn formatSkillResult(
    allocator: std.mem.Allocator,
    display_name: []const u8,
    activation: *const runtime.activation.Activation,
    body: []const u8,
    forked: bool,
) ![]u8 {
    if (forked) return runtime.model_tool.formatResult(allocator, display_name, body, true);
    const with_base = try std.fmt.allocPrint(
        allocator,
        "Base directory for this skill: {s}\n\n{s}",
        .{ activation.tree.path(), body },
    );
    defer allocator.free(with_base);
    return runtime.model_tool.formatResult(allocator, display_name, with_base, false);
}

/// A forked Skill's outcome: the child's final text (owned by `ctx.allocator`)
/// and the bound agent's `permissionMode` when the parent's settings refused it.
const ForkOutput = struct {
    text: []u8,
    refused_mode: ?@import("../agents/def.zig").PermissionMode = null,
};

fn executeFork(
    self: *Runtime,
    ctx: *const ToolContext,
    record: *const runtime.catalog.SkillRecord,
    activation: *const runtime.activation.Activation,
    values: []const []const u8,
) !ForkOutput {
    // A sealed Skill (doc/SEALED_SKILL_PROTOCOL.md §9) runs the same child
    // loop with the gateway as its model; the gateway's shadow of this fork
    // calls the model over this client's own provider route.
    const sealed: ?*sealed_provider.SealedSkillProvider = if (record.definition.isSealed())
        try openSealedProvider(self, ctx, record, activation, values)
    else
        null;
    defer if (sealed) |remote| remote.destroy();
    const api_client: ?*@import("../client.zig").Client = ctx.api_client orelse
        if (sealed == null) return error.ForkUnavailable else null;
    const tool_defs = ctx.tool_defs orelse return error.ForkUnavailable;
    const permission = ctx.permission_ctx orelse return error.ForkUnavailable;
    if (ctx.agent_depth >= agent_tool.MAX_AGENT_DEPTH) return error.AgentDepthExceeded;

    var system_prompt: []const u8 = "You are a subagent. Complete the task and return a concise summary.\n";
    var owned_prompt: ?[]u8 = null;
    defer if (owned_prompt) |prompt| ctx.allocator.free(prompt);
    // `agent:` names the subagent profile a forked Skill runs under (Claude
    // Code): its prompt, tool set, permission mode and model apply, as they do
    // for a Task with that subagent type. Without it the general-purpose
    // prompt is used and the parent's tools pass through the Skill frame.
    const agent_name = if (activation.agent.len != 0) activation.agent else "general-purpose";
    const named_agent: ?*const @import("../agents/def.zig").AgentDef = if (activation.agent.len != 0) blk: {
        const agents = ctx.agents orelse return error.SkillAgentNotFound;
        break :blk agents.find(agent_name) orelse return error.SkillAgentNotFound;
    } else null;
    if (ctx.agents) |agents| {
        if (agents.find(agent_name)) |definition| {
            owned_prompt = try preload.buildSubagentContext(ctx.allocator, definition, .{
                .project_dir = ctx.project_dir,
                .parent_model = ctx.parent_model,
                .session_id = ctx.session_id,
                .skills = ctx.skills,
                // A sealed fork's prompt goes to the gateway: the codebase
                // context (CLAUDE.md chain, git status) travels only under the
                // egress class the user consented to (§5, §6.1).
                .skip_codebase_context = preload.shouldSkipCodebaseContext(definition.name) or
                    (sealed != null and !sealed.?.sendsCodebaseContext()),
                .abort = ctx.abort,
                .sandbox = ctx.sandbox,
                .cwd_abs = ctx.cwd_abs,
                .home_dir = ctx.home_dir,
                .state_root = ctx.state_root,
                .additional_dirs = ctx.additional_dirs,
            });
            system_prompt = owned_prompt.?;
        }
    }

    // skill.model 与 Task 同语义:档位名查当前 provider 档位表(未配置 → inherit),
    // 显式模型名透传。档位 effort 此路径暂不消费(fork 子跑道无 effort override 通道)。
    const model_override = switch (activation.model_selection) {
        .inherit_parent => if (named_agent) |agent| agent_tool.resolveModelSelection(ctx.model_tiers, null, agent.model).model else null,
        .override => |model| agent_tool.resolveModelSelection(ctx.model_tiers, model, null).model,
    };
    var agent_tool_defs: ?[]@import("../json.zig").ToolDefinition = null;
    defer if (agent_tool_defs) |defs| ctx.allocator.free(defs);
    if (named_agent) |agent| agent_tool_defs = try @import("../agents/filter.zig").filterToolDefs(ctx.allocator, tool_defs, agent);
    // The agent's tool set caps dispatch, not just the advertised schema; the
    // Skill frame still narrows it further.
    var agent_tool_cap = @import("../tools/context.zig").ToolSetExecutionPolicy{
        .definitions = agent_tool_defs orelse tool_defs,
        .parent = activation.frame.executionPolicy(),
    };
    const child_execution_policy = if (named_agent != null)
        agent_tool_cap.executionPolicy()
    else
        activation.frame.executionPolicy();
    // The bound agent's permissionMode, unless the parent's settings disable it
    // (then the fork runs as default and the result says so).
    const mode_override: agent_tool.ModeOverride = if (named_agent) |agent|
        agent_tool.resolvePermissionMode(permission, agent.name, agent.permission_mode)
    else
        .{};
    var child_permission = permission.scopedDerive(mode_override.mode);
    child_permission.active_skill = null;
    // A sealed call marked `confirm: true` must be approved interactively
    // whatever the mode (§6.2). The provider does not decide permissions; it
    // answers the kernel's gate, which can only turn an allow into an ask.
    if (sealed) |remote| child_permission.confirm_gate = remote.confirmGate();
    const child_ident = session_id.gen();
    try self.registerChildContext(
        child_ident,
        activation.frame,
        &child_permission,
    );
    // A sealed Skill's rendered body is `$ARGUMENTS` alone (pin.zig): the
    // prompt the gateway receives is the user's request, never a local path.
    const task = if (sealed != null)
        try ctx.allocator.dupe(u8, activation.rendered_body)
    else
        try std.fmt.allocPrint(
            ctx.allocator,
            "Base directory for this skill: {s}\n\n{s}",
            .{ activation.tree.path(), activation.rendered_body },
        );
    defer ctx.allocator.free(task);
    const child_provider = if (sealed) |remote|
        remote.provider()
    else
        ctx.provider orelse api_client.?.provider();
    const result = subagent.spawnAgent(
        ctx.allocator,
        child_provider,
        if (sealed != null) null else api_client,
        agent_tool_defs orelse tool_defs,
        &child_permission,
        ctx.abort,
        task,
        .{
            .system_prompt = system_prompt,
            // A sealed fork's iteration belongs to the gateway's loop; this
            // loop is its executor and sets no shorter turn cap of its own.
            .max_turns = if (sealed) |remote| remote.maxTurns() else 20,
            .agent_depth = ctx.agent_depth + 1,
            .preview = ctx.preview,
            .state_root = ctx.state_root,
            .dyn_registry = ctx.dyn_registry,
            .model_override = if (sealed != null) null else model_override,
            .cost_budget_usd = if (sealed) |remote| remote.costBudgetUsd() else null,
            .host_services = null,
            .session = ctx.session,
            .project_dir = ctx.project_dir,
            .execution_policy = child_execution_policy,
            .agent_ident = child_ident,
        },
    ) catch |run_error| {
        self.unregisterContextStrict(child_ident) catch
            return error.CoreError;
        return run_error;
    };
    defer result.deinit();
    // A sealed run the gateway refused (stale pin, unauthorized, broken
    // chain) is an error of this invocation, not an empty summary.
    if (sealed) |remote| if (remote.lastError()) |err| {
        self.unregisterContextStrict(child_ident) catch
            return error.CoreError;
        return err;
    };
    const output = ctx.allocator.dupe(u8, result.final_text) catch |copy_error| {
        self.unregisterContextStrict(child_ident) catch
            return error.CoreError;
        return copy_error;
    };
    self.unregisterContextStrict(child_ident) catch {
        ctx.allocator.free(output);
        return error.CoreError;
    };
    return .{ .text = output, .refused_mode = mode_override.refused };
}

/// Open the gateway-backed provider for a pinned sealed Skill: the pin is
/// re-read and re-verified from the live directory, it must match the binding
/// the catalog parsed, and the bearer token comes from the pin's environment
/// variable. The cost cap is `METACODES_SEALED_MAX_COST_MICROS` (default
/// USD 0.50 in micro-units). The model is this session's own provider,
/// whose route and credential the gateway's shadow uses (§8.1); a provider
/// that cannot be delegated cannot run sealed Skills.
fn openSealedProvider(
    self: *Runtime,
    ctx: *const ToolContext,
    record: *const runtime.catalog.SkillRecord,
    activation: *const runtime.activation.Activation,
    values: []const []const u8,
) !*sealed_provider.SealedSkillProvider {
    const own_provider: ?@import("../api/provider.zig").Provider = ctx.provider orelse
        if (ctx.api_client) |client| client.provider() else null;
    if (own_provider == null or own_provider.?.route() == null) {
        std.debug.print("\x1b[31m/{s}: a sealed Skill runs on this session's own model account, and the current provider cannot be delegated to a gateway\x1b[0m\n", .{record.invocation_name});
        return error.SealedProviderRouteUnavailable;
    }
    var pin = sealed_pin.read(ctx.allocator, activation.tree.path()) catch |err| {
        std.debug.print("\x1b[31m/{s}: sealed pin unreadable ({s})\x1b[0m\n", .{ record.invocation_name, @errorName(err) });
        return error.SealedPinInvalid;
    };
    // `create` owns the pin from the call on, success or failure; only the
    // checks before it release it here.
    const binding = &record.definition;
    if (!std.mem.eql(u8, pin.pin.entry.manifest_digest, binding.sealed_manifest_digest) or
        !std.mem.eql(u8, pin.pin.entry.skill_id, binding.sealed_skill_id) or
        !std.mem.eql(u8, pin.pin.gateway_url, binding.sealed_gateway))
    {
        pin.deinit();
        return error.SealedPinMismatch;
    }
    if (!pin.pin.entry.manifest.executionSupported()) {
        pin.deinit();
        return error.SealedExecutionUnsupported;
    }
    const token_env = if (pin.pin.token_env.len != 0) pin.pin.token_env else sealed_pin.DEFAULT_TOKEN_ENV;
    const token_z = try ctx.allocator.dupeZ(u8, token_env);
    defer ctx.allocator.free(token_z);
    const token: []const u8 = if (std.c.getenv(token_z.ptr)) |raw| std.mem.span(raw) else "";
    const builtin = @import("builtin");
    return sealed_provider.SealedSkillProvider.create(ctx.allocator, self.io, .{
        .pin = pin,
        .token = token,
        .max_cost_micros = sealedCostCapFromEnv(),
        .session_id = ctx.session_id,
        .state_root = ctx.state_root,
        .client_version = @import("../version.zig").semver,
        .client_platform = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag),
        // An `input_required` question goes to the user over the session's
        // UI channel: the tool-level requester when this is the top-level
        // Skill tool, else the per-session one the permission context carries.
        .ui = ctx.ui_requester orelse if (ctx.permission_ctx) |permission| permission.ui_requester else null,
        .session = ctx.session,
        .origin = own_provider.?,
        .base_dir = activation.tree.path(),
        .arguments = values,
    });
}

fn sealedCostCapFromEnv() i64 {
    const raw = std.c.getenv("METACODES_SEALED_MAX_COST_MICROS") orelse return sealed_provider.DEFAULT_MAX_COST_MICROS;
    const value = std.fmt.parseInt(i64, std.mem.span(raw), 10) catch return sealed_provider.DEFAULT_MAX_COST_MICROS;
    return if (value >= 0) value else sealed_provider.DEFAULT_MAX_COST_MICROS;
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
