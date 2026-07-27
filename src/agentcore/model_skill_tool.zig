//! Run-local model-facing `Skill` tool for a bound Revision 4 catalog.
//!
//! This adapter deliberately lives in AgentCore. It projects one internal
//! provider tool into the existing agent loop, resolves only against the
//! Session-bound immutable snapshot, and reuses the same activation kernel as
//! external typed invocation. It does not add slash or Command semantics.

const std = @import("std");
const core = @import("metacodes-core");
const catalog = @import("skill_catalog.zig");
const activation_mod = @import("skill_activation.zig");
const materialization = @import("skill_materialization.zig");
const policy_frame = @import("policy_frame.zig");
const event_projection = @import("event_projection.zig");

pub const TOOL_NAME = "Skill";

pub const InitError = error{
    OutOfMemory,
    NoModelInvocableSkills,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    session: *core.agent_session.AgentSession,
    materializations: *materialization.Manager,
    snapshot: *const catalog.Snapshot,
    identity: core.agent_session.RunIdentity,
    base_frame: *policy_frame.PolicyFrame,
    abort: *core.util_abort.AbortSignal,
    event_sink: core.agent_session.EventSink,
    max_turns: u32,
    agent_depth: u8 = 0,
};

/// A synchronous Run owns this value at a stable address. Definitions,
/// dispatcher state, PolicyFrames and materialized trees are all borrowed by
/// the agent loop only until that Run (and all child loops) quiesces.
pub const Environment = struct {
    allocator: std.mem.Allocator,
    session: *core.agent_session.AgentSession,
    materializations: *materialization.Manager,
    snapshot: *const catalog.Snapshot,
    identity: core.agent_session.RunIdentity,
    current_frame: *policy_frame.PolicyFrame,
    abort: *core.util_abort.AbortSignal,
    event_sink: core.agent_session.EventSink,
    max_turns: u32,
    agent_depth: u8,

    definitions: []core.json.ToolDefinition,
    properties: []core.json.PropSpec,
    invocation_names: [][]const u8,
    description: []u8,
    inline_activations: std.ArrayList(activation_mod.Activation) = .empty,
    callback_failed: std.atomic.Value(bool) = .init(false),

    pub fn hasModelInvocable(snapshot: *const catalog.Snapshot) bool {
        for (snapshot.skills) |skill| {
            if (!skill.definition.disable_model_invocation) return true;
        }
        return false;
    }

    pub fn init(options: Options) InitError!Environment {
        var invocation_names: std.ArrayList([]const u8) = .empty;
        defer invocation_names.deinit(options.allocator);
        for (options.snapshot.skills) |skill| {
            if (skill.definition.disable_model_invocation) continue;
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

        const description = buildDescription(
            options.allocator,
            options.snapshot,
        ) catch return error.OutOfMemory;
        errdefer options.allocator.free(description);

        const properties = options.allocator.alloc(
            core.json.PropSpec,
            2,
        ) catch return error.OutOfMemory;
        errdefer options.allocator.free(properties);
        properties[0] = .{
            .name = "name",
            .type = "string",
            .description = "Canonical invocation_name from the bound Skill catalog",
            .enum_values = owned_names,
        };
        properties[1] = .{
            .name = "values",
            .type = "array",
            .description = "Optional positional argument values in declared order",
            .items_type = "string",
        };

        const base_definitions = options.session.tools.definitions;
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
                .required = &.{"name"},
            },
        };

        return .{
            .allocator = options.allocator,
            .session = options.session,
            .materializations = options.materializations,
            .snapshot = options.snapshot,
            .identity = options.identity,
            .current_frame = options.base_frame,
            .abort = options.abort,
            .event_sink = options.event_sink,
            .max_turns = options.max_turns,
            .agent_depth = options.agent_depth,
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
        };
    }

    fn dispatch(
        raw: *const anyopaque,
        tool_ctx: *const core.tool_context.ToolContext,
        name: []const u8,
        arguments_json: []const u8,
    ) anyerror!core.tools.ToolDispatchOutcome {
        const self: *Environment = @ptrCast(@alignCast(@constCast(raw)));
        if (!std.mem.eql(u8, name, TOOL_NAME)) {
            return self.session.tools.dispatcher().dispatch(
                tool_ctx,
                name,
                arguments_json,
            );
        }
        return self.invokeSkill(tool_ctx, arguments_json);
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
        if (index < self.session.tools.definitions.len)
            return self.session.tools.dispatcher().nameAt(index);
        if (index == self.session.tools.definitions.len) return TOOL_NAME;
        return null;
    }

    fn hostSync(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, name, TOOL_NAME)) return false;
        return self.session.tools.dispatcher().isHostSync(name);
    }

    fn allowsTool(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, name, TOOL_NAME)) return true;
        return self.current_frame.executionPolicy().allowsTool(name);
    }

    fn allowsInvocation(
        raw: *const anyopaque,
        name: []const u8,
        arguments_json: []const u8,
    ) bool {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, name, TOOL_NAME)) return true;
        return self.current_frame.executionPolicy().allowsInvocation(
            name,
            arguments_json,
        );
    }

    fn invokeSkill(
        self: *Environment,
        tool_ctx: *const core.tool_context.ToolContext,
        arguments_json: []const u8,
    ) anyerror!core.tools.ToolDispatchOutcome {
        if (arguments_json.len > activation_mod.MAX_ARGUMENT_JSON_BYTES)
            return error.ResourceLimit;
        if (!std.unicode.utf8ValidateSlice(arguments_json))
            return error.InvalidArguments;

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const parsed = try parseInvocation(
            scratch.allocator(),
            arguments_json,
        );
        const skill = self.snapshot.findByInvocation(parsed.name) orelse
            return error.SkillNotFound;
        const canonical_arguments = try encodeArguments(
            scratch.allocator(),
            parsed.values,
        );

        var plan = try activation_mod.prepare(
            self.allocator,
            self.snapshot,
            &self.snapshot.revision,
            &skill.skill_id,
            canonical_arguments,
            self.current_frame.shellPolicy(),
            .model_tool,
        );
        defer plan.deinit();

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
        const output = std.fmt.allocPrint(
            output_allocator,
            "# Skill: {s}\n\n{s}",
            .{ skill.definition.name, owned_activation.rendered_body },
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
        return .{ .ok = output };
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
            .identity = self.identity,
            .base_frame = activation.frame,
            .abort = self.abort,
            .event_sink = self.event_sink,
            .max_turns = self.max_turns,
            .agent_depth = child_depth,
        }) catch |err| {
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
        const model_override: ?[]const u8 =
            if (plan.skill.definition.model.len == 0 or
            std.mem.eql(u8, plan.skill.definition.model, "inherit"))
                null
            else
                plan.skill.definition.model;
        const host_run: ?core.agent_session.HostRunIdentity =
            if (self.session.host_identity_ctx) |host_ctx| .{
                .identity = self.identity,
                .host_session_ctx = host_ctx,
            } else null;

        const child = core.subagent.spawnAgentSink(
            self.allocator,
            self.session.provider.provider(),
            self.session.provider.anthropicClient(),
            child_environment.definitions,
            &self.session.permission_ctx,
            self.abort,
            activation.rendered_body,
            .{
                .max_turns = self.max_turns,
                .system_prompt = "You are a subagent. Complete the task and return a concise final answer.\n",
                .session = self.identity.session_id,
                .agent_depth = child_depth,
                .tool_dispatcher = child_environment.dispatcher(),
                .execution_policy = child_environment.executionPolicy(),
                .host_run = host_run,
                .ui_requester = self.session.permission_ctx.ui_requester,
                .read_state = &self.session.read_state,
                .jobs = if (self.session.jobs) |*jobs| jobs else null,
                .event_projection = .model_tool,
                .model_override = model_override,
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
        const output = std.fmt.allocPrint(
            output_allocator,
            "# Skill: {s} (forked)\n\n{s}",
            .{ plan.skill.definition.name, final_text.items },
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
        return .{ .ok = output };
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

const ParsedInvocation = struct {
    name: []const u8,
    values: []const []const u8,
};

fn parseInvocation(
    arena: std.mem.Allocator,
    encoded: []const u8,
) !ParsedInvocation {
    const root = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        encoded,
        .{ .duplicate_field_behavior = .@"error" },
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidArguments;
    };
    if (root != .object or root.object.count() < 1 or root.object.count() > 2)
        return error.InvalidArguments;
    const name_node = root.object.get("name") orelse
        return error.InvalidArguments;
    if (name_node != .string or name_node.string.len == 0)
        return error.InvalidArguments;

    const values_node = root.object.get("values");
    if (root.object.count() == 2 and values_node == null)
        return error.InvalidArguments;
    const values = if (values_node) |node| blk: {
        if (node != .array or
            node.array.items.len > activation_mod.MAX_ARGUMENT_VALUES)
            return error.InvalidArguments;
        const result = try arena.alloc([]const u8, node.array.items.len);
        for (node.array.items, result) |item, *value| {
            if (item != .string) return error.InvalidArguments;
            value.* = item.string;
        }
        break :blk result;
    } else &.{};
    return .{ .name = name_node.string, .values = values };
}

fn encodeArguments(
    arena: std.mem.Allocator,
    values: []const []const u8,
) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(arena);
    defer output.deinit();
    try output.writer.writeAll("{\"values\":[");
    for (values, 0..) |value, index| {
        if (index != 0) try output.writer.writeByte(',');
        try std.json.Stringify.encodeJsonString(value, .{}, &output.writer);
    }
    try output.writer.writeAll("]}");
    return try output.toOwnedSlice();
}

fn buildDescription(
    allocator: std.mem.Allocator,
    snapshot: *const catalog.Snapshot,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll(
        "Activate one Skill from the Session-bound immutable catalog. " ++
            "Use the exact canonical name; values are positional. Skill is a " ++
            "serialization boundary, so later calls use its narrowed policy. Available:\n",
    );
    for (snapshot.skills) |skill| {
        if (skill.definition.disable_model_invocation) continue;
        try output.writer.print(
            "- {s}: {s}\n",
            .{ skill.invocation_name, skill.definition.description },
        );
    }
    return try output.toOwnedSlice();
}

fn childDepth(parent: u8) error{AgentDepthExceeded}!u8 {
    if (parent >= core.tool_context.MAX_AGENT_DEPTH)
        return error.AgentDepthExceeded;
    return parent + 1;
}

test "model invocation parser accepts exact name plus optional string values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseInvocation(
        arena.allocator(),
        "{\"name\":\"review\",\"values\":[\"a\",\"b\"]}",
    );
    try std.testing.expectEqualStrings("review", parsed.name);
    try std.testing.expectEqual(@as(usize, 2), parsed.values.len);
    try std.testing.expectEqualStrings("a", parsed.values[0]);
}

test "model invocation parser rejects unknown fields and non-string values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.InvalidArguments,
        parseInvocation(
            arena.allocator(),
            "{\"name\":\"review\",\"origin\":\"MODEL\"}",
        ),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseInvocation(
            arena.allocator(),
            "{\"name\":\"review\",\"values\":[1]}",
        ),
    );
}
