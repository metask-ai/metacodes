//! Run-local model-facing `Skill` tool for a bound Revision 6 Skill binding.
//!
//! This adapter deliberately lives in AgentCore. It projects one internal
//! provider tool into the existing agent loop, resolves only against the
//! Session-bound immutable snapshot, and reuses the same activation kernel as
//! external typed invocation. It does not add slash or Command semantics.

const std = @import("std");
const core = @import("metacodes-core");
const skill_runtime = core.skills_runtime;
const catalog = skill_runtime.catalog;
const availability = skill_runtime.availability;
const activation_mod = skill_runtime.activation;
const materialization = skill_runtime.materialization;
const policy_frame = skill_runtime.policy_frame;
const model_semantics = skill_runtime.model_tool;
const event_projection = @import("event_projection.zig");
const model_binding = @import("model_binding.zig");
const mcp_session = @import("mcp_session.zig");
const session_budget = @import("session_budget.zig");
const child_permission = @import("child_permission.zig");

pub const TOOL_NAME = model_semantics.TOOL_NAME;

pub const InitError = error{
    OutOfMemory,
    NoModelInvocableSkills,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    session: *core.agent_session.AgentSession,
    materializations: *materialization.Manager,
    snapshot: *const catalog.Snapshot,
    availability: availability.View,
    identity: core.agent_session.RunIdentity,
    base_frame: *policy_frame.PolicyFrame,
    abort: *core.util_abort.AbortSignal,
    event_sink: core.agent_session.EventSink,
    max_turns: u32,
    agent_depth: u8 = 0,
    /// Optional AgentCore-owned lower overlay (currently the Session MCP
    /// view). Skill remains the outer policy boundary and may only narrow it.
    base_surface: ?core.agent_session.RunToolSurface = null,
    base_policy: ?core.tools.ToolExecutionPolicy = null,
    mcp_view: ?*const mcp_session.View = null,
    initial_mcp_restrictions: []const mcp_session.SkillRestriction = &.{},
    /// Borrowed from the synchronous AgentCore Run. Nested fork Skills share
    /// the same atomic durable-state reservation controller.
    budget_controller: ?*session_budget.Controller = null,
    /// Same logical-Session authority, plus AgentCore-owned provenance hooks
    /// used to derive a non-interactive fork scope.
    permission_owner: child_permission.Owner,
};

/// A synchronous Run owns this value at a stable address. Definitions,
/// dispatcher state, PolicyFrames and materialized trees are all borrowed by
/// the agent loop only until that Run (and all child loops) quiesces.
pub const Environment = struct {
    allocator: std.mem.Allocator,
    session: *core.agent_session.AgentSession,
    materializations: *materialization.Manager,
    snapshot: *const catalog.Snapshot,
    availability: availability.View,
    identity: core.agent_session.RunIdentity,
    current_frame: *policy_frame.PolicyFrame,
    abort: *core.util_abort.AbortSignal,
    event_sink: core.agent_session.EventSink,
    max_turns: u32,
    agent_depth: u8,
    base_definitions: []const core.json.ToolDefinition,
    base_dispatcher: core.tools.ToolDispatcher,
    base_policy: ?core.tools.ToolExecutionPolicy,
    mcp_view: ?*const mcp_session.View,
    budget_controller: ?*session_budget.Controller,
    permission_owner: child_permission.Owner,
    mcp_restrictions: std.ArrayList(mcp_session.SkillRestriction) = .empty,

    definitions: []core.json.ToolDefinition,
    properties: []core.json.PropSpec,
    invocation_names: [][]const u8,
    description: []u8,
    inline_activations: std.ArrayList(activation_mod.Activation) = .empty,
    callback_failed: std.atomic.Value(bool) = .init(false),

    pub fn hasModelInvocable(
        snapshot: *const catalog.Snapshot,
        available: availability.View,
    ) bool {
        return model_semantics.hasModelInvocableWithAvailability(
            snapshot,
            available,
        );
    }

    pub fn init(options: Options) InitError!Environment {
        var invocation_names: std.ArrayList([]const u8) = .empty;
        defer invocation_names.deinit(options.allocator);
        for (options.snapshot.skills, 0..) |skill, index| {
            if (!options.availability.isEnabledAt(options.snapshot, index) or
                skill.definition.disable_model_invocation)
                continue;
            invocation_names.append(
                options.allocator,
                skill.invocation_name,
            ) catch return error.OutOfMemory;
        }
        if (invocation_names.items.len == 0)
            return error.NoModelInvocableSkills;

        const owned_names = invocation_names.toOwnedSlice(
            options.allocator,
        ) catch return error.OutOfMemory;
        errdefer options.allocator.free(owned_names);

        const description = model_semantics.buildDescriptionWithAvailability(
            options.allocator,
            options.snapshot,
            options.availability,
        ) catch return error.OutOfMemory;
        errdefer options.allocator.free(description);

        const properties = options.allocator.alloc(
            core.json.PropSpec,
            model_semantics.INPUT_PROPERTIES.len,
        ) catch return error.OutOfMemory;
        errdefer options.allocator.free(properties);
        @memcpy(properties, &model_semantics.INPUT_PROPERTIES);
        properties[0].enum_values = owned_names;

        const base_definitions = if (options.base_surface) |base|
            base.definitions
        else
            options.session.tools.definitions;
        const base_dispatcher = if (options.base_surface) |base|
            base.dispatcher
        else
            options.session.tools.dispatcher();
        const definitions = options.allocator.alloc(
            core.json.ToolDefinition,
            base_definitions.len + 1,
        ) catch return error.OutOfMemory;
        errdefer options.allocator.free(definitions);
        @memcpy(definitions[0..base_definitions.len], base_definitions);
        definitions[base_definitions.len] = .{
            .name = TOOL_NAME,
            .description = description,
            .input_schema = .{
                .type = "object",
                .prop_specs = properties,
                .required = model_semantics.REQUIRED_FIELDS,
            },
            .model_activation = model_semantics.modelActivationWithAvailability(
                options.snapshot,
                options.availability,
            ),
        };

        var mcp_restrictions: std.ArrayList(mcp_session.SkillRestriction) = .empty;
        errdefer mcp_restrictions.deinit(options.allocator);
        mcp_restrictions.appendSlice(
            options.allocator,
            options.initial_mcp_restrictions,
        ) catch return error.OutOfMemory;

        return .{
            .allocator = options.allocator,
            .session = options.session,
            .materializations = options.materializations,
            .snapshot = options.snapshot,
            .availability = options.availability,
            .identity = options.identity,
            .current_frame = options.base_frame,
            .abort = options.abort,
            .event_sink = options.event_sink,
            .max_turns = options.max_turns,
            .agent_depth = options.agent_depth,
            .base_definitions = base_definitions,
            .base_dispatcher = base_dispatcher,
            .base_policy = options.base_policy,
            .mcp_view = options.mcp_view,
            .budget_controller = options.budget_controller,
            .permission_owner = options.permission_owner,
            .mcp_restrictions = mcp_restrictions,
            .definitions = definitions,
            .properties = properties,
            .invocation_names = owned_names,
            .description = description,
        };
    }

    /// Release every inline activation in reverse lineage order. A failed
    /// tree cleanup is reported after all in-memory ownership is still
    /// released; the materialization manager itself has already failed closed.
    pub fn deinit(self: *Environment) error{CoreError}!void {
        var cleanup_failed = false;
        var index = self.inline_activations.items.len;
        while (index != 0) {
            index -= 1;
            self.inline_activations.items[index].deinit() catch {
                cleanup_failed = true;
            };
        }
        self.inline_activations.deinit(self.allocator);
        self.mcp_restrictions.deinit(self.allocator);
        self.allocator.free(self.definitions);
        self.allocator.free(self.properties);
        self.allocator.free(self.invocation_names);
        self.allocator.free(self.description);
        self.* = undefined;
        if (cleanup_failed) return error.CoreError;
    }

    pub fn surface(self: *Environment) core.agent_session.RunToolSurface {
        return .{
            .definitions = self.definitions,
            .dispatcher = self.dispatcher(),
        };
    }

    pub fn executionPolicy(
        self: *Environment,
    ) core.tools.ToolExecutionPolicy {
        return .{
            .ctx = self,
            .allowsToolFn = allowsTool,
            .allowsInvocationFn = allowsInvocation,
        };
    }

    pub fn callbackFailed(self: *const Environment) bool {
        return self.callback_failed.load(.acquire);
    }

    fn dispatcher(self: *Environment) core.tools.ToolDispatcher {
        return .{
            .ctx = self,
            .dispatchFn = dispatch,
            .prefetchSafeFn = prefetchSafe,
            .nameAtFn = nameAt,
            .hostSyncFn = hostSync,
            .builtinFn = isBuiltin,
            .categoryFn = category,
            .replayDeclarationFn = replayDeclaration,
        };
    }

    const ToolOwner = enum { skill, base };

    fn resolveTool(name: []const u8) ToolOwner {
        return if (std.mem.eql(u8, name, TOOL_NAME)) .skill else .base;
    }

    fn dispatch(
        raw: *const anyopaque,
        tool_ctx: *const core.tool_context.ToolContext,
        name: []const u8,
        arguments_json: []const u8,
    ) anyerror!core.tools.ToolDispatchOutcome {
        const self: *Environment = @ptrCast(@alignCast(@constCast(raw)));
        return switch (resolveTool(name)) {
            .skill => self.invokeSkill(tool_ctx, arguments_json),
            .base => self.base_dispatcher.dispatch(
                tool_ctx,
                name,
                arguments_json,
            ),
        };
    }

    fn prefetchSafe(_: *const anyopaque, _: []const u8) bool {
        // Skill mutates the Run-local current PolicyFrame in provider order.
        // Allowing a later Read/Glob to prefetch while the response is still
        // streaming would execute it against the parent frame before an
        // earlier Skill call narrows authority. Disable speculation for the
        // whole overlay; executeSlots still preserves ordinary safe batching
        // on either side of the serial Skill boundary.
        return false;
    }

    fn nameAt(raw: *const anyopaque, index: usize) ?[]const u8 {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (index < self.base_definitions.len)
            return self.base_dispatcher.nameAt(index);
        if (index == self.base_definitions.len) return TOOL_NAME;
        return null;
    }

    fn hostSync(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        return switch (resolveTool(name)) {
            .skill => false,
            .base => self.base_dispatcher.isHostSync(name),
        };
    }

    fn isBuiltin(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        return switch (resolveTool(name)) {
            .skill => false,
            .base => self.base_dispatcher.isBuiltin(name),
        };
    }

    fn category(raw: *const anyopaque, name: []const u8) ?core.tool_context.ToolCategory {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        return switch (resolveTool(name)) {
            .skill => null,
            .base => self.base_dispatcher.category(name),
        };
    }

    fn replayDeclaration(raw: *const anyopaque, name: []const u8) core.tools.ReplayDeclaration {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        return switch (resolveTool(name)) {
            .skill => .never,
            .base => self.base_dispatcher.replayDeclaration(name),
        };
    }

    fn allowsTool(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, name, TOOL_NAME))
            return self.current_frame.allowsSkillTool();
        if (self.mcp_view) |view| if (view.findModelTool(name) != null) {
            if (!view.allowsSkillRestrictions(name, self.mcp_restrictions.items))
                return false;
            return if (self.base_policy) |policy| policy.allowsTool(name) else true;
        };
        if (!self.current_frame.executionPolicy().allowsTool(name)) return false;
        return if (self.base_policy) |policy| policy.allowsTool(name) else true;
    }

    fn allowsInvocation(
        raw: *const anyopaque,
        name: []const u8,
        arguments_json: []const u8,
    ) bool {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, name, TOOL_NAME))
            return self.current_frame.allowsSkillInvocation(arguments_json);
        if (self.mcp_view) |view| if (view.findModelTool(name) != null) {
            if (!view.allowsSkillRestrictions(name, self.mcp_restrictions.items))
                return false;
            return if (self.base_policy) |policy|
                policy.allowsInvocation(name, arguments_json)
            else
                true;
        };
        if (!self.current_frame.executionPolicy().allowsInvocation(name, arguments_json))
            return false;
        return if (self.base_policy) |policy|
            policy.allowsInvocation(name, arguments_json)
        else
            true;
    }

    fn invokeSkill(
        self: *Environment,
        tool_ctx: *const core.tool_context.ToolContext,
        arguments_json: []const u8,
    ) anyerror!core.tools.ToolDispatchOutcome {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const parsed = try model_semantics.parseInvocation(
            scratch.allocator(),
            arguments_json,
        );
        const skill = self.snapshot.findByInvocation(parsed.name) orelse
            return error.SkillNotFound;
        if (self.mcp_view != null and skill.definition.context == .inline_ctx)
            self.mcp_restrictions.ensureUnusedCapacity(
                self.allocator,
                1,
            ) catch return error.OutOfMemory;

        var plan = try activation_mod.prepareValues(
            self.allocator,
            self.snapshot,
            &self.snapshot.revision,
            &skill.skill_id,
            parsed.values,
            .{
                .context = .model_tool,
                .shell_policy = self.current_frame.shellPolicy(),
                .model_override_capability = .forbidden,
                .availability = self.availability,
            },
        );
        defer plan.deinit();
        model_binding.requireSessionModel(plan.model_selection) catch |err| {
            core.util_log.err(
                "agentcore",
                "Skill model binding invariant violated: {s}",
                .{@errorName(err)},
            );
            return err;
        };

        var activation = try activation_mod.activate(
            self.allocator,
            &plan,
            .{
                .materializations = self.materializations,
                .parent_frame = self.current_frame,
                .abort = self.abort,
                .project_dir = self.session.workspace.root,
                .session_id = self.identity.session_id.asSlice(),
                .sandbox = self.session.workspace.sandbox(),
                .cwd_abs = self.session.workspace.root,
                .home_dir = self.session.workspace.home,
                .additional_dirs = self.session.permission_ctx.match_ctx.additional_dirs,
                .parent_agent_depth = self.agent_depth,
            },
        );

        return switch (skill.definition.context) {
            .inline_ctx => self.activateInline(
                tool_ctx.allocator,
                skill,
                activation,
            ),
            .fork => self.executeFork(
                tool_ctx.allocator,
                &plan,
                &activation,
            ),
        };
    }

    fn activateInline(
        self: *Environment,
        output_allocator: std.mem.Allocator,
        skill: *const catalog.SkillRecord,
        activation: activation_mod.Activation,
    ) anyerror!core.tools.ToolDispatchOutcome {
        var owned_activation = activation;
        const output = model_semantics.formatResult(
            output_allocator,
            skill.definition.name,
            owned_activation.rendered_body,
            false,
        ) catch |err| {
            owned_activation.deinit() catch return error.CoreError;
            return err;
        };
        self.inline_activations.append(
            self.allocator,
            owned_activation,
        ) catch |err| {
            output_allocator.free(output);
            owned_activation.deinit() catch return error.CoreError;
            return err;
        };
        self.current_frame = owned_activation.frame;
        if (self.mcp_view != null) self.mcp_restrictions.appendAssumeCapacity(.{
            .allowed = skill.definition.allowed_tools,
            .disallowed = skill.definition.disallowed_tools,
        });
        return .{ .ok = core.tools.ToolResultBody.initInline(output) };
    }

    fn executeFork(
        self: *Environment,
        output_allocator: std.mem.Allocator,
        plan: *const activation_mod.ActivationPlan,
        activation: *activation_mod.Activation,
    ) anyerror!core.tools.ToolDispatchOutcome {
        const child_depth = try childDepth(self.agent_depth);
        var child_environment = Environment.init(.{
            .allocator = self.allocator,
            .session = self.session,
            .materializations = self.materializations,
            .snapshot = self.snapshot,
            .availability = self.availability,
            .identity = self.identity,
            .base_frame = activation.frame,
            .abort = self.abort,
            .event_sink = self.event_sink,
            .max_turns = self.max_turns,
            .agent_depth = child_depth,
            .base_surface = .{
                .definitions = self.base_definitions,
                .dispatcher = self.base_dispatcher,
            },
            .base_policy = self.base_policy,
            .mcp_view = self.mcp_view,
            .initial_mcp_restrictions = self.mcp_restrictions.items,
            .budget_controller = self.budget_controller,
            .permission_owner = self.permission_owner,
        }) catch |err| {
            activation.deinit() catch return error.CoreError;
            return err;
        };
        if (self.mcp_view != null) child_environment.mcp_restrictions.append(
            self.allocator,
            .{
                .allowed = plan.skill.definition.allowed_tools,
                .disallowed = plan.skill.definition.disallowed_tools,
            },
        ) catch |err| {
            child_environment.deinit() catch return error.CoreError;
            activation.deinit() catch return error.CoreError;
            return err;
        };

        var projection_downstream = child_environment.eventBackend();
        var projector = event_projection.Projector.init(
            self.allocator,
            .model_tool,
            &projection_downstream,
        );
        defer projector.deinit();
        const child_backend = projector.backend();
        var permission_lease = child_permission.Lease{};
        permission_lease.init(self.permission_owner, &projector);
        defer permission_lease.deinit();
        const host_run: ?core.agent_session.HostRunIdentity =
            if (self.session.host_identity_ctx) |host_ctx| .{
                .identity = self.identity,
                .host_session_ctx = host_ctx,
            } else null;

        var budget_provider: ?session_budget.BudgetedProvider = if (self.budget_controller) |controller| .{
            .allocator = self.allocator,
            .controller = controller,
            .base = self.session.provider.provider(),
        } else null;
        var budget_tools: ?session_budget.ToolEnvironment = if (self.budget_controller) |controller| .{
            .controller = controller,
            .base = child_environment.surface(),
            .mcp_view = self.mcp_view,
        } else null;
        const child_surface = if (budget_tools) |*tools|
            tools.surface()
        else
            child_environment.surface();

        // 缺陷 A 修复:子 Agent 系统提示 = 静态字面量 + 环境段(cwd=workspace.root)。
        // 与 abi_v1.zig 共用 buildSubagentSystemPrompt,确保两路径一致。
        const sp_mod = core.system_prompt;
        const owned_subagent_system_prompt = sp_mod.buildSubagentSystemPrompt(
            self.allocator,
            self.session.model,
            self.session.workspace.root,
        ) catch null;
        defer if (owned_subagent_system_prompt) |prompt| self.allocator.free(prompt);
        const subagent_system_prompt = owned_subagent_system_prompt orelse
            sp_mod.SUBAGENT_LITERAL;

        const child = core.subagent.spawnAgentSink(
            self.allocator,
            if (budget_provider) |*provider|
                provider.provider()
            else
                self.session.provider.provider(),
            self.session.provider.anthropicClient(),
            child_surface.definitions,
            permission_lease.permissionContext(),
            self.abort,
            activation.rendered_body,
            .{
                .max_turns = self.max_turns,
                .system_prompt = subagent_system_prompt,
                .session = self.identity.session_id,
                .agent_depth = child_depth,
                .tool_dispatcher = child_surface.dispatcher,
                .execution_policy = child_environment.executionPolicy(),
                .host_run = host_run,
                // SubagentResult has no resumable suspend payload. Allowing a
                // child UI request here would lose that payload at this
                // adapter boundary, so model-tool children fail closed.
                .ui_requester = null,
                .read_state = &self.session.read_state,
                .jobs = if (self.session.jobs) |*jobs| jobs else null,
                .event_projection = .model_tool,
                .model_override = null,
                .project_dir = self.session.workspace.root,
                .sandbox = self.session.workspace.sandbox(),
                .cwd_abs = self.session.workspace.root,
                .resolve_relative_paths = true,
                .home_dir = self.session.workspace.home,
                .additional_dirs = self.session.permission_ctx.match_ctx.additional_dirs,
            },
            &child_backend,
        ) catch |run_error| {
            const callback_failed = child_environment.callbackFailed();
            var cleanup_failed = false;
            child_environment.deinit() catch {
                cleanup_failed = true;
            };
            activation.deinit() catch {
                cleanup_failed = true;
            };
            if (callback_failed) return .host_fatal;
            if (cleanup_failed) return error.CoreError;
            return run_error;
        };
        defer child.deinit();

        var final_text: std.ArrayList(u8) = .empty;
        defer final_text.deinit(self.allocator);
        projector.appendFinalText(&final_text) catch |projection_error| {
            var cleanup_failed = false;
            child_environment.deinit() catch {
                cleanup_failed = true;
            };
            activation.deinit() catch {
                cleanup_failed = true;
            };
            if (cleanup_failed) return error.CoreError;
            return projection_error;
        };
        const output = model_semantics.formatResult(
            output_allocator,
            plan.skill.definition.name,
            final_text.items,
            true,
        ) catch |output_error| {
            var cleanup_failed = false;
            child_environment.deinit() catch {
                cleanup_failed = true;
            };
            activation.deinit() catch {
                cleanup_failed = true;
            };
            if (cleanup_failed) return error.CoreError;
            return output_error;
        };

        const callback_failed = child_environment.callbackFailed();
        var cleanup_failed = false;
        child_environment.deinit() catch {
            cleanup_failed = true;
        };
        activation.deinit() catch {
            cleanup_failed = true;
        };
        if (callback_failed) {
            output_allocator.free(output);
            return .host_fatal;
        }
        if (cleanup_failed) {
            output_allocator.free(output);
            return error.CoreError;
        }
        return .{ .ok = core.tools.ToolResultBody.initInline(output) };
    }

    fn eventBackend(self: *Environment) core.protocol.ui_backend.UiBackend {
        return .{
            .ctx = self,
            .emit = emitEvent,
            .poll = pollEvent,
        };
    }

    fn emitEvent(
        raw: *anyopaque,
        _: core.session_id.SessionId,
        event: core.protocol.ui_event.CoreEvent,
    ) void {
        const self: *Environment = @ptrCast(@alignCast(raw));
        if (self.callback_failed.load(.acquire)) return;
        if (!self.event_sink.emit(
            self.event_sink.ctx,
            self.identity.session_id,
            self.identity.run_id,
            event,
        )) {
            self.callback_failed.store(true, .release);
            self.abort.abort(.host_failure);
        }
    }

    fn pollEvent(
        _: *anyopaque,
        _: core.session_id.SessionId,
    ) ?core.protocol.ui_event.UiEvent {
        return null;
    }
};

fn childDepth(parent: u8) error{AgentDepthExceeded}!u8 {
    if (parent >= core.tool_context.MAX_AGENT_DEPTH)
        return error.AgentDepthExceeded;
    return parent + 1;
}

test "Skill metadata preserves base identity category and replay while disabling prefetch" {
    const Base = struct {
        fn dispatch(
            _: *const anyopaque,
            _: *const core.tool_context.ToolContext,
            _: []const u8,
            _: []const u8,
        ) anyerror!core.tools.ToolDispatchOutcome {
            return .host_fatal;
        }
        fn nameAt(_: *const anyopaque, index: usize) ?[]const u8 {
            return if (index == 0) "Read" else null;
        }
        fn prefetchSafe(_: *const anyopaque, name: []const u8) bool {
            return std.mem.eql(u8, name, "Read");
        }
        fn hostSync(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn isBuiltin(_: *const anyopaque, name: []const u8) bool {
            return std.mem.eql(u8, name, "Read");
        }
        fn category(_: *const anyopaque, name: []const u8) ?core.tool_context.ToolCategory {
            return if (std.mem.eql(u8, name, "Read")) .read else null;
        }
        fn replayDeclaration(_: *const anyopaque, name: []const u8) core.tools.ReplayDeclaration {
            return if (std.mem.eql(u8, name, "Read")) .read_only else .never;
        }
        fn dispatcher() core.tools.ToolDispatcher {
            return .{
                .ctx = &unit,
                .dispatchFn = dispatch,
                .prefetchSafeFn = prefetchSafe,
                .nameAtFn = nameAt,
                .hostSyncFn = hostSync,
                .builtinFn = isBuiltin,
                .categoryFn = category,
                .replayDeclarationFn = replayDeclaration,
            };
        }
        const unit: u8 = 0;
    };

    var environment: Environment = undefined;
    environment.base_dispatcher = Base.dispatcher();
    const dispatcher = environment.dispatcher();

    try std.testing.expectEqual(Environment.ToolOwner.skill, Environment.resolveTool(TOOL_NAME));
    try std.testing.expectEqual(Environment.ToolOwner.base, Environment.resolveTool("Read"));
    try std.testing.expect(!dispatcher.prefetchSafe(TOOL_NAME));
    try std.testing.expect(!dispatcher.isHostSync(TOOL_NAME));
    try std.testing.expect(!dispatcher.isBuiltin(TOOL_NAME));
    try std.testing.expect(dispatcher.category(TOOL_NAME) == null);
    try std.testing.expectEqual(core.tools.ReplayDeclaration.never, dispatcher.replayDeclaration(TOOL_NAME));
    try std.testing.expect(!dispatcher.prefetchSafe("Read"));
    try std.testing.expect(!dispatcher.isHostSync("Read"));
    try std.testing.expect(dispatcher.isBuiltin("Read"));
    try std.testing.expectEqual(core.tool_context.ToolCategory.read, dispatcher.category("Read").?);
    try std.testing.expectEqual(core.tools.ReplayDeclaration.read_only, dispatcher.replayDeclaration("Read"));
    try std.testing.expect(!dispatcher.isBuiltin("unknown"));
    try std.testing.expect(dispatcher.category("unknown") == null);
}

test "Skill execution policy cannot re-authorize a denied MCP base tool" {
    const Deny = struct {
        fn tool(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn invocation(_: *const anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        fn policy() core.tools.ToolExecutionPolicy {
            return .{
                .ctx = &unit,
                .allowsToolFn = tool,
                .allowsInvocationFn = invocation,
            };
        }
        const unit: u8 = 0;
    };
    const model_name = "mcp__weather__0123456789abcdef0123456789abcdef";
    const root = try policy_frame.PolicyFrame.createRoot(
        std.testing.allocator,
        &.{model_name},
        .sandboxed,
        .default,
        .{ .cwd = "/work", .project_root = "/work", .home = "/home/test" },
    );
    defer root.release();
    var environment: Environment = undefined;
    environment.current_frame = root;
    environment.base_policy = Deny.policy();
    environment.mcp_view = null;
    environment.mcp_restrictions = .empty;
    try std.testing.expect(!environment.executionPolicy().allowsTool(model_name));
    try std.testing.expect(!environment.executionPolicy().allowsInvocation(
        model_name,
        "{\"city\":\"Paris\"}",
    ));
    const definition = core.json.ToolDefinition{
        .name = model_name,
        .description = "MCP inheritance fixture",
        .input_schema = .{},
    };
    var child = core.tool_context.ToolSetExecutionPolicy{
        .definitions = &.{definition},
        .parent = environment.executionPolicy(),
    };
    try std.testing.expect(!child.executionPolicy().allowsInvocation(
        model_name,
        "{\"city\":\"Paris\"}",
    ));

    // Both layers must agree. Removing the lower denial exposes the current
    // Skill frame's own decision. A child agent still intersects its selected
    // definitions with that parent and can never widen either layer.
    environment.base_policy = null;
    child.parent = environment.executionPolicy();
    try std.testing.expect(environment.executionPolicy().allowsInvocation(
        model_name,
        "{\"city\":\"Paris\"}",
    ));
    try std.testing.expect(child.executionPolicy().allowsInvocation(
        model_name,
        "{\"city\":\"Paris\"}",
    ));
    var narrowed_child = core.tool_context.ToolSetExecutionPolicy{
        .definitions = &.{},
        .parent = environment.executionPolicy(),
    };
    try std.testing.expect(!narrowed_child.executionPolicy().allowsTool(model_name));
}

test "Skill execution policy matches MCP metadata against canonical tool identity" {
    const fixture = @import("mcp_test_support.zig");
    const mcp_catalog = @import("mcp_catalog.zig");
    var server = fixture.Server{};
    const binding = [_]u8{0x65} ** 32;
    const specs = [_]mcp_catalog.ServerSpec{.{
        .binding = binding,
        .namespace = "weather",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try mcp_catalog.Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    _ = try manager.refresh();
    const snapshot = try manager.retainCurrent();
    defer snapshot.release();
    var view = try mcp_session.View.init(std.testing.allocator, snapshot, &.{.{
        .server_binding_identity = binding,
        .tool_name = "weather",
    }}, .fresh);
    defer view.deinit();
    const alias = view.entries[0].model_name;
    const root = try policy_frame.PolicyFrame.createRoot(
        std.testing.allocator,
        &.{alias},
        .sandboxed,
        .default,
        .{ .cwd = "/work", .project_root = "/work", .home = "/home/test" },
    );
    defer root.release();
    var environment: Environment = undefined;
    environment.current_frame = root;
    environment.base_policy = null;
    environment.mcp_view = &view;
    environment.mcp_restrictions = .empty;
    defer environment.mcp_restrictions.deinit(std.testing.allocator);
    try environment.mcp_restrictions.append(std.testing.allocator, .{
        .allowed = &.{"mcp__weather__weather"},
        .disallowed = &.{},
    });
    try std.testing.expect(environment.executionPolicy().allowsInvocation(
        alias,
        "{\"city\":\"Paris\"}",
    ));
    environment.mcp_restrictions.clearRetainingCapacity();
    try environment.mcp_restrictions.append(std.testing.allocator, .{
        .allowed = &.{"mcp__weather"},
        .disallowed = &.{"mcp__weather__weather"},
    });
    try std.testing.expect(!environment.executionPolicy().allowsInvocation(
        alias,
        "{\"city\":\"Paris\"}",
    ));
}
