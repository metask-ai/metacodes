//! Thin C ABI v1 facade over AgentRuntime and AgentSession.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("platform").sync;
const wire = @import("metask_agentcore_types");
const core = @import("metacodes-core");
const ui_request = core.protocol.ui_request;
pub const protocol_v1 = @import("protocol_v1.zig");
const skill_runtime = core.skills_runtime;
pub const skill_catalog = skill_runtime.catalog;
pub const skill_availability = skill_runtime.availability;
pub const skill_catalog_handles = @import("skill_catalog_handles.zig");
pub const skill_activation = skill_runtime.activation;
pub const skill_materialization = skill_runtime.materialization;
pub const policy_frame = skill_runtime.policy_frame;
pub const event_projection = @import("event_projection.zig");
pub const model_skill_tool = @import("model_skill_tool.zig");
const model_binding = @import("model_binding.zig");
const sandbox_admission = @import("sandbox_admission.zig");

const allocator = std.heap.c_allocator;

comptime {
    if (wire.MAX_TOOL_ERROR_PAYLOAD_BYTES_V1 != @as(u64, core.tool_exec.MAX_TOOL_ERROR_PAYLOAD_BYTES_V1))
        @compileError("AgentCore wire and core encoded Host-error limits must match");
    if ((skill_catalog.Limits{}).max_slots != @as(usize, @intCast(wire.MAX_SKILL_CATALOG_SKILLS_V1)))
        @compileError("AgentCore wire and Skill catalog slot limits must match");
    const permission_limits = core.permission_settings.RuleSetLimits{};
    if (permission_limits.max_rules != @as(usize, @intCast(wire.MAX_PERMISSION_RULES_V1)) or
        permission_limits.max_rule_bytes != @as(usize, @intCast(wire.MAX_PERMISSION_RULE_BYTES_V1)) or
        permission_limits.max_total_bytes != @as(usize, @intCast(wire.MAX_PERMISSION_RULE_TOTAL_BYTES_V1)))
        @compileError("AgentCore wire and canonical permission rule limits must match");
}

const AbiHostTool = struct {
    ctx: ?*anyopaque,
    execute_fn: wire.HostExecuteFnV1,
    release_fn: wire.HostReleaseFnV1,

    /// HOST_FATAL and unknown statuses are infrastructure-fatal. FAILED and
    /// REJECTED may carry bounded UTF-8 detail; malformed detail degrades to a
    /// null-detail business failure. An invalid HOST_OK descriptor is fatal.
    fn execute(raw: *anyopaque, identity: core.agent_session.HostRunIdentity, args: []const u8) error{OutOfMemory}!core.agent_session.HostToolOutcome {
        const self: *AbiHostTool = @ptrCast(@alignCast(raw));
        const session: *wire.SessionHandle = @ptrCast(identity.host_session_ctx);
        const run = makeRunContext(session, &identity.identity);
        var out = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
        const status = self.execute_fn(self.ctx, &run, view(args), &out);
        if (status == wire.HOST_FATAL or
            (status != wire.HOST_OK and status != wire.HOST_FAILED and status != wire.HOST_REJECTED))
        {
            if (hasReleaseToken(out)) self.release_fn(self.ctx, &out);
            return .fatal;
        }
        if (!canonicalOwned(out)) {
            if (hasReleaseToken(out)) self.release_fn(self.ctx, &out);
            return outcomeWithoutDetail(status);
        }
        if (out.len == 0) {
            if (status == wire.HOST_OK) {
                return .{ .ok = .{ .bytes = "", .release_ctx = self, .releaseFn = release } };
            }
            return outcomeWithoutDetail(status);
        }

        // The wire descriptor has one raw-text limit for every business
        // status. FAILED/REJECTED detail is later serialized under the smaller
        // encoded-payload cap; applying that cap here would reject valid raw
        // detail before escaping is measured.
        if (out.len > wire.MAX_HOST_TOOL_RESULT_BYTES_V1) {
            if (hasReleaseToken(out)) self.release_fn(self.ctx, &out);
            return outcomeWithInvalidPayload(status);
        }
        const bytes = ownedSlice(out) catch {
            if (hasReleaseToken(out)) self.release_fn(self.ctx, &out);
            return outcomeWithInvalidPayload(status);
        };
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            if (hasReleaseToken(out)) self.release_fn(self.ctx, &out);
            return outcomeWithInvalidPayload(status);
        }
        const result = core.agent_session.HostToolResult{ .bytes = bytes, .release_ctx = self, .releaseFn = release };
        return switch (status) {
            wire.HOST_OK => .{ .ok = result },
            wire.HOST_FAILED => .{ .failed = result },
            wire.HOST_REJECTED => .{ .rejected = result },
            else => unreachable,
        };
    }

    fn outcomeWithoutDetail(status: u32) core.agent_session.HostToolOutcome {
        return switch (status) {
            wire.HOST_OK => .fatal,
            wire.HOST_FAILED => .{ .failed = null },
            wire.HOST_REJECTED => .{ .rejected = null },
            else => .fatal,
        };
    }

    fn outcomeWithInvalidPayload(status: u32) core.agent_session.HostToolOutcome {
        return switch (status) {
            wire.HOST_OK, wire.HOST_FAILED => .{ .failed = null },
            wire.HOST_REJECTED => .{ .rejected = null },
            else => .fatal,
        };
    }

    fn release(raw: *anyopaque, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const self: *AbiHostTool = @ptrCast(@alignCast(raw));
        var out = wire.OwnedBytesV1{ .ptr = @constCast(bytes.ptr), .len = bytes.len };
        self.release_fn(self.ctx, &out);
    }
};

const AbiRuntime = struct {
    core_runtime: *core.agent_session.AgentRuntime,
    host_tools: []AbiHostTool,
    catalogs: skill_catalog_handles.RuntimeCatalogs,
    materializations: skill_materialization.Manager,

    fn handle(self: *AbiRuntime) *wire.RuntimeHandle {
        return @ptrCast(self);
    }
};

const SkillBinding = struct {
    cell: *skill_catalog_handles.CatalogCell,
    selection: skill_availability.Selection,

    fn snapshot(self: *const SkillBinding) *const skill_catalog.Snapshot {
        return self.cell.snapshot;
    }

    fn view(self: *const SkillBinding) skill_availability.View {
        return .{ .selected = &self.selection };
    }

    fn deinit(
        self: *SkillBinding,
        catalogs: *skill_catalog_handles.RuntimeCatalogs,
    ) void {
        self.selection.deinit();
        catalogs.releaseSession(self.cell);
        self.* = undefined;
    }
};

fn createInitialSkillBinding(
    runtime: *AbiRuntime,
    workspace_scope_id: *const [64]u8,
    optional_host: ?*const skill_catalog_handles.HostCatalog,
    optional_spec: ?*const skill_availability.Spec,
) !?SkillBinding {
    var runtime_call = try runtime.catalogs.enterCall();
    defer runtime_call.deinit();
    if ((optional_host == null) != (optional_spec == null))
        return error.InvalidSkillBinding;
    const host = optional_host orelse return null;
    const spec = optional_spec.?;
    const cell = try runtime.catalogs.retainForSession(
        host,
        workspace_scope_id,
    );
    errdefer runtime.catalogs.releaseSession(cell);
    return .{
        .cell = cell,
        .selection = try skill_availability.Selection.init(
            allocator,
            cell.snapshot,
            spec.*,
        ),
    };
}

const AbiSession = struct {
    const CallState = enum { idle, running, compacting, mutating, destroying };

    callbacks: wire.SessionCallbacksV1,
    callback_status: std.atomic.Value(u32),
    facade_poisoned: std.atomic.Value(bool),
    core_session: *core.agent_session.AgentSession,
    runtime: ?*AbiRuntime = null,
    workspace_scope_id: [64]u8 = [_]u8{0} ** 64,
    skill_binding: ?SkillBinding = null,
    /// Null only in narrow unit-test fakes. Every live Session created through
    /// the ABI owns exactly one immutable baseline frame.
    policy_root: ?*policy_frame.PolicyFrame = null,
    call_mutex: sync.Mutex = .{},
    call_state: CallState = .idle,

    fn handle(self: *AbiSession) *wire.SessionHandle {
        return @ptrCast(self);
    }

    fn runContext(self: *AbiSession, identity: *const core.agent_session.RunIdentity) wire.RunContextV1 {
        return makeRunContext(self.handle(), identity);
    }

    fn emit(raw: *anyopaque, session_id: core.session_id.SessionId, run_id: u64, event: core.protocol.ui_event.CoreEvent) bool {
        const self: *AbiSession = @ptrCast(@alignCast(raw));
        const callback = self.callbacks.on_event orelse return true;
        const public_event = protocol_v1.event(event) orelse return true;
        const json = std.json.Stringify.valueAlloc(allocator, public_event, .{}) catch {
            self.recordCallbackStatus(wire.STATUS_OUT_OF_MEMORY);
            return false;
        };
        defer allocator.free(json);
        const identity = core.agent_session.RunIdentity{ .session_id = session_id, .run_id = run_id };
        const run = self.runContext(&identity);
        const accepted = callback(self.callbacks.ctx, &run, view(json)) == wire.EVENT_CONTINUE;
        if (!accepted) self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
        return accepted;
    }

    fn requestUi(raw: *anyopaque, identity: core.agent_session.RunIdentity, response_allocator: std.mem.Allocator, req: *const ui_request.UiRequest, out: *ui_request.UiResponse) anyerror!ui_request.RequestOutcome {
        const self: *AbiSession = @ptrCast(@alignCast(raw));

        if (rememberedPermission(self, req)) |choice| {
            out.* = .{ .permission = choice };
            return .answered;
        }
        const callback = self.callbacks.on_ui_request orelse return switch (req.*) {
            .permission => blk: {
                out.* = .{ .permission = .deny_once };
                break :blk .answered;
            },
            else => .unavailable,
        };
        const release_fn = self.callbacks.release_response orelse return error.HostUiFailed;
        const request_json = protocol_v1.encodeUiRequest(response_allocator, req) catch |err| {
            self.recordCallbackStatus(if (err == error.OutOfMemory) wire.STATUS_OUT_OF_MEMORY else wire.STATUS_INTERNAL_ERROR);
            return err;
        };
        defer response_allocator.free(request_json);
        var response = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
        const run = self.runContext(&identity);
        const status = callback(self.callbacks.ctx, &run, view(request_json), &response);
        defer if (hasReleaseToken(response)) release_fn(self.callbacks.ctx, &response);
        if (!canonicalOwned(response)) {
            self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
            return error.HostUiFailed;
        }
        return switch (status) {
            wire.UI_UNAVAILABLE => switch (req.*) {
                .permission => blk: {
                    out.* = .{ .permission = .deny_once };
                    break :blk .answered;
                },
                else => .unavailable,
            },
            wire.UI_CANCELLED => switch (req.*) {
                .permission => blk: {
                    out.* = .{ .permission = .deny_once };
                    break :blk .answered;
                },
                .ask_question => return error.UiCancelled,
                else => unreachable,
            },
            wire.UI_ANSWERED => blk: {
                if (response.len > wire.MAX_UI_RESPONSE_BYTES_V1) {
                    self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                    return error.HostUiFailed;
                }
                const bytes = ownedSlice(response) catch |err| {
                    self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                    return err;
                };
                protocol_v1.decodeUiResponse(response_allocator, req, bytes, out) catch |err| {
                    self.recordCallbackStatus(if (err == error.OutOfMemory) wire.STATUS_OUT_OF_MEMORY else wire.STATUS_CALLBACK_FAILED);
                    return err;
                };
                self.captureSessionPermission(req, out);
                break :blk .answered;
            },
            else => {
                self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                return error.HostUiFailed;
            },
        };
    }

    fn rememberedPermission(self: *AbiSession, req: *const ui_request.UiRequest) ?core.protocol.PermissionChoice {
        const permission = switch (req.*) {
            .permission => |value| value,
            else => return null,
        };
        return switch (self.core_session.session_rules.decisionFor(permission.tool) orelse return null) {
            .allow => .allow_once,
            .deny => .deny_once,
        };
    }

    fn captureSessionPermission(self: *AbiSession, req: *const ui_request.UiRequest, out: *ui_request.UiResponse) void {
        const permission = switch (req.*) {
            .permission => |value| value,
            else => return,
        };
        // The Host already observes and may persist its own response. Core gets
        // only a one-shot projection so product settings persistence remains
        // unreachable from the AgentCore path.
        switch (out.*) {
            .permission => |choice| switch (choice) {
                .allow_always => {
                    self.core_session.session_rules.rememberAllow(permission.tool);
                    out.* = .{ .permission = .allow_once };
                },
                .deny_tool_session => {
                    self.core_session.session_rules.rememberDeny(permission.tool);
                    out.* = .{ .permission = .deny_once };
                },
                .allow_once, .deny_once => {},
            },
            else => {},
        }
    }

    fn recordCallbackStatus(self: *AbiSession, status: u32) void {
        _ = self.callback_status.cmpxchgStrong(wire.STATUS_OK, status, .release, .monotonic);
    }

    fn callbackFailureStatus(self: *const AbiSession) u32 {
        const status = self.callback_status.load(.acquire);
        return if (status == wire.STATUS_OK) wire.STATUS_CALLBACK_FAILED else status;
    }

    fn tryBeginRun(self: *AbiSession) bool {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        if (self.call_state != .idle) return false;
        self.call_state = .running;
        return true;
    }

    fn finishRun(self: *AbiSession) void {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        std.debug.assert(self.call_state == .running);
        self.call_state = .idle;
    }

    fn tryBeginCompact(self: *AbiSession) bool {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        if (self.call_state != .idle) return false;
        self.call_state = .compacting;
        return true;
    }

    fn finishCompact(self: *AbiSession) void {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        std.debug.assert(self.call_state == .compacting);
        self.call_state = .idle;
    }

    fn tryBeginMutation(self: *AbiSession) bool {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        if (self.call_state != .idle) return false;
        self.call_state = .mutating;
        return true;
    }

    fn finishMutation(self: *AbiSession) void {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        std.debug.assert(self.call_state == .mutating);
        self.call_state = .idle;
    }

    fn tryBeginDestroy(self: *AbiSession) bool {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        if (self.call_state != .idle) return false;
        self.call_state = .destroying;
        return true;
    }

    fn cancelDestroy(self: *AbiSession) void {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        std.debug.assert(self.call_state == .destroying);
        self.call_state = .idle;
    }

    fn updateSkills(
        self: *AbiSession,
        optional_host: ?*const skill_catalog_handles.HostCatalog,
        spec: skill_availability.Spec,
    ) !void {
        if (self.facade_poisoned.load(.acquire))
            return error.InvalidSessionState;
        const runtime = self.runtime orelse return error.InvalidSessionState;
        var runtime_call = try runtime.catalogs.enterCall();
        defer runtime_call.deinit();
        if (!self.tryBeginMutation()) return error.SessionBusy;
        defer self.finishMutation();
        try self.updateSkillsAdmitted(runtime, optional_host, spec);
    }

    fn updateSkillsAdmitted(
        self: *AbiSession,
        runtime: *AbiRuntime,
        optional_host: ?*const skill_catalog_handles.HostCatalog,
        spec: skill_availability.Spec,
    ) !void {
        if (optional_host) |host| {
            const replacement_cell = try runtime.catalogs.retainForSession(
                host,
                &self.workspace_scope_id,
            );
            errdefer runtime.catalogs.releaseSession(replacement_cell);
            var replacement_selection = try skill_availability.Selection.init(
                allocator,
                replacement_cell.snapshot,
                spec,
            );
            errdefer replacement_selection.deinit();

            const previous = self.skill_binding;
            self.skill_binding = .{
                .cell = replacement_cell,
                .selection = replacement_selection,
            };
            if (previous) |binding_value| {
                var binding = binding_value;
                binding.deinit(&runtime.catalogs);
            }
            return;
        }

        const snapshot = if (self.skill_binding) |*binding|
            binding.snapshot()
        else
            return error.SkillCatalogNotBound;
        const replacement_selection = try skill_availability.Selection.init(
            allocator,
            snapshot,
            spec,
        );
        const previous_selection = self.skill_binding.?.selection;
        self.skill_binding.?.selection = replacement_selection;
        var previous = previous_selection;
        previous.deinit();
    }

    /// Internal Revision 5 adapter. The public wire entry point is frozen only
    /// after the Core contract and the ABI lifecycle gate pass their tests.
    fn setModel(self: *AbiSession, model: []const u8) !void {
        if (self.facade_poisoned.load(.acquire))
            return error.InvalidSessionState;
        if (!self.tryBeginMutation()) return error.SessionBusy;
        defer self.finishMutation();
        try self.core_session.setModel(model);
    }

    /// Internal Revision 5 adapter. Host rules are compiled by the canonical
    /// Core parser/matcher; the facade contributes only lifecycle admission.
    fn updatePermissionRules(
        self: *AbiSession,
        input: core.permission_settings.RuleSetInput,
    ) !void {
        if (self.facade_poisoned.load(.acquire))
            return error.InvalidSessionState;
        if (!self.tryBeginMutation()) return error.SessionBusy;
        defer self.finishMutation();
        try self.core_session.updatePermissionRules(input);
    }

    /// Internal typed-Skill entry used by the Revision 5 public input union.
    /// All validation before `admitMaterializedSkill` is side-effect free.
    fn runSkill(
        self: *AbiSession,
        materializations: *skill_materialization.Manager,
        run_id: u64,
        catalog_revision: []const u8,
        skill_id: []const u8,
        arguments_json: []const u8,
        max_turns: u32,
    ) anyerror!SkillExecution {
        const binding = if (self.skill_binding) |*value| value else return error.SkillCatalogNotBound;
        const root_frame = self.policy_root orelse
            return error.InvalidSessionState;
        var plan = try skill_activation.prepare(
            allocator,
            binding.snapshot(),
            catalog_revision,
            skill_id,
            arguments_json,
            .{
                .context = .external_run_root,
                .shell_policy = root_frame.shellPolicy(),
                .model_override_capability = .forbidden,
                .availability = binding.view(),
            },
        );
        defer plan.deinit();
        try model_binding.requireSessionModel(plan.model_selection);
        if (!materializations.supportsExactFileModes())
            return error.SkillUnavailable;

        return switch (try self.admitMaterializedSkill(
            materializations,
            run_id,
            &plan,
            root_frame,
        )) {
            .aborted => .aborted,
            .ready => |ready_value| blk: {
                var ready = ready_value;
                break :blk switch (plan.skill.definition.context) {
                    .inline_ctx => try ready.executeInline(&plan, max_turns),
                    .fork => try ready.executeFork(&plan, max_turns),
                };
            },
        };
    }

    fn runTextWithBoundSkills(
        self: *AbiSession,
        materializations: *skill_materialization.Manager,
        run_id: u64,
        prompt: []const u8,
        max_turns: u32,
    ) anyerror!SkillExecution {
        const binding = if (self.skill_binding) |*value| value else {
            return .{ .completed = try self.core_session.runText(
                run_id,
                prompt,
                max_turns,
                .{ .ctx = self, .emit = AbiSession.emit },
            ) };
        };
        if (!materializations.supportsExactFileModes() or
            !model_skill_tool.Environment.hasModelInvocable(
                binding.snapshot(),
                binding.view(),
            ))
        {
            return .{ .completed = try self.core_session.runText(
                run_id,
                prompt,
                max_turns,
                .{ .ctx = self, .emit = AbiSession.emit },
            ) };
        }
        const root_frame = self.policy_root orelse
            return error.InvalidSessionState;
        const identity = core.agent_session.RunIdentity{
            .session_id = self.core_session.session_id,
            .run_id = run_id,
        };
        var environment = try model_skill_tool.Environment.init(.{
            .allocator = allocator,
            .session = self.core_session,
            .materializations = materializations,
            .snapshot = binding.snapshot(),
            .availability = binding.view(),
            .identity = identity,
            .base_frame = root_frame,
            .abort = &self.core_session.abort_signal,
            .event_sink = .{ .ctx = self, .emit = AbiSession.emit },
            .max_turns = max_turns,
        });
        var environment_live = true;
        defer if (environment_live) environment.deinit() catch {};

        var admitted = try self.core_session.admitRun(
            run_id,
            .{ .ctx = self, .emit = AbiSession.emit },
        );
        const result = admitted.runUserMessagesWithToolSurface(
            &.{prompt},
            max_turns,
            environment.executionPolicy(),
            environment.surface(),
        ) catch |run_error| {
            const callback_failed = environment.callbackFailed();
            environment.deinit() catch {
                environment_live = false;
                return error.AdmittedCleanupFailed;
            };
            environment_live = false;
            if (callback_failed) return error.CallbackFailed;
            return run_error;
        };
        environment.deinit() catch {
            environment_live = false;
            return error.AdmittedCleanupFailed;
        };
        environment_live = false;
        return .{ .completed = result };
    }

    /// Caller holds the facade Run gate and Runtime active-call guard. Pure
    /// ActivationPlan validation has already completed before this admitted
    /// boundary.
    fn admitMaterializedSkill(
        self: *AbiSession,
        materializations: *skill_materialization.Manager,
        run_id: u64,
        plan: *const skill_activation.ActivationPlan,
        parent_frame: *policy_frame.PolicyFrame,
    ) anyerror!SkillAdmission {
        var admitted = try self.core_session.admitRun(
            run_id,
            .{ .ctx = self, .emit = AbiSession.emit },
        );
        var activation = skill_activation.activate(allocator, plan, .{
            .materializations = materializations,
            .parent_frame = parent_frame,
            .abort = admitted.abortSignal(),
            .project_dir = self.core_session.workspace.root,
            .session_id = admitted.identity().session_id.asSlice(),
            .sandbox = self.core_session.workspace.sandbox(),
            .cwd_abs = self.core_session.workspace.root,
            .home_dir = self.core_session.workspace.home,
        }) catch |activation_error| {
            const completion = try admitted.finishWithoutConversation();
            if (activation_error != error.OutOfMemory and
                (activation_error == error.Aborted or completion.aborted))
                return .aborted;
            return activation_error;
        };
        if (admitted.abortSignal().isAborted()) {
            var cleanup_failed = false;
            activation.deinit() catch {
                cleanup_failed = true;
            };
            _ = try admitted.finishWithoutConversation();
            if (cleanup_failed) return error.CoreError;
            return .aborted;
        }
        return .{ .ready = .{
            .facade = self,
            .materializations = materializations,
            .admitted = admitted,
            .activation = activation,
        } };
    }
};

const SkillAdmission = union(enum) {
    aborted,
    ready: MaterializedSkillRun,
};

const SkillExecution = union(enum) {
    aborted,
    completed: core.agent_loop.RunResult,
};

const MaterializedSkillRun = struct {
    facade: *AbiSession,
    materializations: *skill_materialization.Manager,
    admitted: core.agent_session.AdmittedRun,
    activation: skill_activation.Activation,

    fn executeInline(
        self: *MaterializedSkillRun,
        plan: *const skill_activation.ActivationPlan,
        max_turns: u32,
    ) anyerror!SkillExecution {
        const invocation_record = canonicalInvocationRecord(
            allocator,
            plan,
        ) catch |record_error| {
            _ = try self.finishWithoutConversation();
            return record_error;
        };
        defer allocator.free(invocation_record);

        const body_record = core.skills_runtime.model_tool.formatResult(
            allocator,
            plan.skill.definition.name,
            self.activation.rendered_body,
            false,
        ) catch |body_error| {
            _ = try self.finishWithoutConversation();
            return body_error;
        };
        defer allocator.free(body_record);

        if (self.admitted.abortSignal().isAborted()) {
            _ = try self.finishWithoutConversation();
            return .aborted;
        }

        const binding = if (self.facade.skill_binding) |*value| value else {
            _ = try self.finishWithoutConversation();
            return error.InvalidSessionState;
        };
        var environment: ?model_skill_tool.Environment =
            if (model_skill_tool.Environment.hasModelInvocable(
                binding.snapshot(),
                binding.view(),
            ))
                model_skill_tool.Environment.init(.{
                    .allocator = allocator,
                    .session = self.admitted.session,
                    .materializations = self.materializations,
                    .snapshot = binding.snapshot(),
                    .availability = binding.view(),
                    .identity = self.admitted.identity(),
                    .base_frame = self.activation.frame,
                    .abort = @constCast(self.admitted.abortSignal()),
                    .event_sink = .{
                        .ctx = self.facade,
                        .emit = AbiSession.emit,
                    },
                    .max_turns = max_turns,
                }) catch |environment_error| {
                    _ = try self.finishWithoutConversation();
                    return environment_error;
                }
            else
                null;
        var environment_live = environment != null;
        defer if (environment_live) environment.?.deinit() catch {};
        const result = (if (environment) |*env|
            self.admitted.runUserMessagesWithToolSurface(
                &.{ invocation_record, body_record },
                max_turns,
                env.executionPolicy(),
                env.surface(),
            )
        else
            self.admitted.runUserMessagesWithPolicy(
                &.{ invocation_record, body_record },
                max_turns,
                self.activation.frame.executionPolicy(),
            )) catch |run_error| {
            const callback_failed = if (environment) |*env|
                env.callbackFailed()
            else
                false;
            var cleanup_failed = false;
            if (environment) |*env| env.deinit() catch {
                cleanup_failed = true;
            };
            environment_live = false;
            self.releaseAssets() catch {
                cleanup_failed = true;
            };
            if (cleanup_failed) return error.AdmittedCleanupFailed;
            if (callback_failed) return error.CallbackFailed;
            return run_error;
        };
        var cleanup_failed = false;
        if (environment) |*env| env.deinit() catch {
            cleanup_failed = true;
        };
        environment_live = false;
        self.releaseAssets() catch {
            cleanup_failed = true;
        };
        if (cleanup_failed) return error.AdmittedCleanupFailed;
        return .{ .completed = result };
    }

    fn executeFork(
        self: *MaterializedSkillRun,
        plan: *const skill_activation.ActivationPlan,
        max_turns: u32,
    ) anyerror!SkillExecution {
        const invocation_record = canonicalInvocationRecord(
            allocator,
            plan,
        ) catch |record_error| {
            _ = try self.finishWithoutConversation();
            return record_error;
        };
        defer allocator.free(invocation_record);

        if (self.admitted.abortSignal().isAborted()) {
            _ = try self.finishWithoutConversation();
            return .aborted;
        }

        var executor_context = ForkExecutorContext{
            .facade = self.facade,
            .session = self.admitted.session,
            .materializations = self.materializations,
            .activation = &self.activation,
            .plan = plan,
            .max_turns = max_turns,
        };
        const result = self.admitted.runIsolated(
            &.{invocation_record},
            .{
                .ctx = &executor_context,
                .executeFn = ForkExecutorContext.execute,
            },
        ) catch |run_error| {
            self.releaseAssets() catch
                return error.AdmittedCleanupFailed;
            return run_error;
        };
        self.releaseAssets() catch return error.AdmittedCleanupFailed;
        return .{ .completed = result };
    }

    fn releaseAssets(self: *MaterializedSkillRun) !void {
        self.activation.deinit() catch return error.CoreError;
    }

    /// Test/rollback path before prompt rendering. Always closes the core
    /// lifecycle even if filesystem cleanup reports failure.
    fn finishWithoutConversation(
        self: *MaterializedSkillRun,
    ) anyerror!core.agent_session.AdmittedCompletion {
        var cleanup_failed = false;
        self.releaseAssets() catch {
            cleanup_failed = true;
        };
        const completion = try self.admitted.finishWithoutConversation();
        if (cleanup_failed) return error.CoreError;
        return completion;
    }
};

const ForkExecutorContext = struct {
    facade: *AbiSession,
    session: *core.agent_session.AgentSession,
    materializations: *skill_materialization.Manager,
    activation: *skill_activation.Activation,
    plan: *const skill_activation.ActivationPlan,
    max_turns: u32,

    fn execute(
        raw: *anyopaque,
        output_allocator: std.mem.Allocator,
        identity: core.agent_session.RunIdentity,
        downstream: *const core.protocol.ui_backend.UiBackend,
        abort: *const core.util_abort.AbortSignal,
        out_final_text: *std.ArrayList(u8),
    ) anyerror!core.agent_loop.RunResult {
        const self: *ForkExecutorContext = @ptrCast(@alignCast(raw));
        const mode: event_projection.Mode = switch (self.plan.context) {
            .external_run_root => .external_run_root,
            .model_tool => .model_tool,
        };
        var projector = event_projection.Projector.init(
            output_allocator,
            mode,
            downstream,
        );
        defer projector.deinit();
        const child_backend = projector.backend();
        const host_run: ?core.agent_session.HostRunIdentity =
            if (self.session.host_identity_ctx) |host_ctx| .{
                .identity = identity,
                .host_session_ctx = host_ctx,
            } else null;
        const child_depth = try childDepth(self.activation.parent_agent_depth);
        const binding = if (self.facade.skill_binding) |*value| value else return error.InvalidSessionState;
        var environment: ?model_skill_tool.Environment =
            if (model_skill_tool.Environment.hasModelInvocable(
                binding.snapshot(),
                binding.view(),
            ))
                try model_skill_tool.Environment.init(.{
                    .allocator = output_allocator,
                    .session = self.session,
                    .materializations = self.materializations,
                    .snapshot = binding.snapshot(),
                    .availability = binding.view(),
                    .identity = identity,
                    .base_frame = self.activation.frame,
                    .abort = @constCast(abort),
                    .event_sink = .{
                        .ctx = self.facade,
                        .emit = AbiSession.emit,
                    },
                    .max_turns = self.max_turns,
                    .agent_depth = child_depth,
                })
            else
                null;
        var environment_live = environment != null;
        defer if (environment_live) environment.?.deinit() catch {};
        const definitions = if (environment) |*env|
            env.definitions
        else
            self.session.tools.definitions;
        const dispatcher = if (environment) |*env|
            env.surface().dispatcher
        else
            self.session.tools.dispatcher();
        const execution_policy = if (environment) |*env|
            env.executionPolicy()
        else
            self.activation.frame.executionPolicy();

        // 缺陷 A 修复:子 Agent 系统提示 = 静态字面量 + 环境段(cwd=workspace.root)。
        // 与 model_skill_tool.zig 共用 buildSubagentSystemPrompt,确保两路径一致。
        const sp_mod = @import("../core/system_prompt.zig");
        const owned_subagent_system_prompt = sp_mod.buildSubagentSystemPrompt(
            output_allocator,
            self.session.model,
            self.session.workspace.root,
        ) catch null;
        defer if (owned_subagent_system_prompt) |prompt| output_allocator.free(prompt);
        const subagent_system_prompt = owned_subagent_system_prompt orelse
            "You are a subagent. Complete the task and return a concise final answer.\n";

        const child = core.subagent.spawnAgentSink(
            output_allocator,
            self.session.provider.provider(),
            self.session.provider.anthropicClient(),
            definitions,
            &self.session.permission_ctx,
            abort,
            self.activation.rendered_body,
            .{
                .max_turns = self.max_turns,
                .system_prompt = subagent_system_prompt,
                .session = identity.session_id,
                .agent_depth = child_depth,
                .tool_dispatcher = dispatcher,
                .execution_policy = execution_policy,
                .host_run = host_run,
                // SubagentResult has no resumable suspend payload. Allowing a
                // child UI request here would lose that payload at this
                // adapter boundary, so fork children fail closed instead.
                .ui_requester = null,
                .read_state = &self.session.read_state,
                .jobs = if (self.session.jobs) |*jobs| jobs else null,
                .event_projection = switch (mode) {
                    .external_run_root => .run_root,
                    .model_tool => .model_tool,
                },
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
            const callback_failed = if (environment) |*env|
                env.callbackFailed()
            else
                false;
            if (callback_failed) return error.CallbackFailed;
            return run_error;
        };
        defer child.deinit();
        try projector.appendFinalText(out_final_text);
        if (environment) |*env| {
            try env.deinit();
            environment_live = false;
        }
        return .{
            .stop_reason = child.stop_reason,
            .turns = child.turns,
            .tool_calls = child.tool_calls,
        };
    }

    fn childDepth(parent: u8) error{AgentDepthExceeded}!u8 {
        if (parent >= core.tool_context.MAX_AGENT_DEPTH)
            return error.AgentDepthExceeded;
        return parent + 1;
    }
};

fn canonicalInvocationRecord(
    output_allocator: std.mem.Allocator,
    plan: *const skill_activation.ActivationPlan,
) error{OutOfMemory}![]u8 {
    var output: std.Io.Writer.Allocating = .init(output_allocator);
    defer output.deinit();
    output.writer.writeAll(
        "{\"type\":\"metask.skill-invocation/v1\",\"catalog_revision\":\"",
    ) catch return error.OutOfMemory;
    output.writer.writeAll(&plan.snapshot.revision) catch return error.OutOfMemory;
    output.writer.writeAll("\",\"skill_id\":\"") catch return error.OutOfMemory;
    output.writer.writeAll(&plan.skill.skill_id) catch return error.OutOfMemory;
    output.writer.writeAll("\",\"invocation_name\":") catch return error.OutOfMemory;
    std.json.Stringify.encodeJsonString(
        plan.skill.invocation_name,
        .{},
        &output.writer,
    ) catch return error.OutOfMemory;
    output.writer.writeAll(",\"arguments\":{\"values\":[") catch return error.OutOfMemory;
    for (plan.arguments, 0..) |argument, index| {
        if (index != 0) output.writer.writeByte(',') catch return error.OutOfMemory;
        std.json.Stringify.encodeJsonString(
            argument,
            .{},
            &output.writer,
        ) catch return error.OutOfMemory;
    }
    output.writer.writeAll("]}}") catch return error.OutOfMemory;
    return output.toOwnedSlice() catch error.OutOfMemory;
}

pub const TestEpilogueHook = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, run_id: u64) void,
};

var test_epilogue_hook: if (builtin.is_test) ?TestEpilogueHook else void = if (builtin.is_test) null else {};

pub fn setTestEpilogueHook(hook: ?TestEpilogueHook) void {
    if (comptime !builtin.is_test) @compileError("test epilogue hooks are unavailable in production builds");
    test_epilogue_hook = hook;
}

fn invokeTestEpilogueHook(run_id: u64) void {
    if (comptime builtin.is_test) {
        if (test_epilogue_hook) |hook| hook.runFn(hook.ctx, run_id);
    }
}

fn makeRunContext(session: *wire.SessionHandle, identity: *const core.agent_session.RunIdentity) wire.RunContextV1 {
    return .{
        .struct_size = @sizeOf(wire.RunContextV1),
        .reserved0 = 0,
        .session = session,
        .run_id = identity.run_id,
        .session_id = view(identity.session_id.asSlice()),
        .reserved = [_]u64{0} ** 2,
    };
}

fn runtimeFrom(handle: *wire.RuntimeHandle) *AbiRuntime {
    return @ptrCast(@alignCast(handle));
}
fn sessionFrom(handle: *wire.SessionHandle) *AbiSession {
    return @ptrCast(@alignCast(handle));
}
fn catalogFrom(handle: *wire.SkillCatalogHandle) *skill_catalog_handles.HostCatalog {
    return @ptrCast(@alignCast(handle));
}
fn catalogHandle(catalog: *skill_catalog_handles.HostCatalog) *wire.SkillCatalogHandle {
    return @ptrCast(catalog);
}

fn view(bytes: []const u8) wire.BytesViewV1 {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

fn borrowed(v: wire.BytesViewV1) error{ InvalidArgument, Overflow }![]const u8 {
    const len = std.math.cast(usize, v.len) orelse return error.Overflow;
    if (len == 0) return "";
    return (v.ptr orelse return error.InvalidArgument)[0..len];
}

fn text(v: wire.BytesViewV1) ![]const u8 {
    const bytes = try borrowed(v);
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    return bytes;
}

fn ownedSlice(v: wire.OwnedBytesV1) error{ InvalidArgument, Overflow }![]const u8 {
    return borrowed(.{ .ptr = v.ptr, .len = v.len });
}

fn canonicalOwned(v: wire.OwnedBytesV1) bool {
    return (v.len == 0) == (v.ptr == null);
}

fn canonicalEmpty(v: wire.BytesViewV1) bool {
    return v.ptr == null and v.len == 0;
}

fn hasReleaseToken(v: wire.OwnedBytesV1) bool {
    return v.ptr != null or v.len != 0;
}

fn allZero(values: anytype) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

fn emptyError(out_error: ?*wire.OwnedBytesV1) void {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
}

fn writeDiagnostic(diagnostic_allocator: std.mem.Allocator, message: []const u8, out_error: ?*wire.OwnedBytesV1) void {
    const out = out_error orelse return;
    // Diagnostics are best-effort side output. Failure to allocate human-readable
    // text must never replace the machine-readable status of the operation.
    out.* = .{ .ptr = null, .len = 0 };
    const copy = diagnostic_allocator.dupe(u8, message) catch return;
    out.* = .{ .ptr = copy.ptr, .len = copy.len };
}

fn fail(status: u32, message: []const u8, out_error: ?*wire.OwnedBytesV1) u32 {
    writeDiagnostic(allocator, message, out_error);
    return status;
}

fn failError(status: u32, err: anyerror, out_error: ?*wire.OwnedBytesV1) u32 {
    var buf: [192]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "{s}: {s}", .{ statusText(status), @errorName(err) }) catch "AgentCore operation failed";
    return fail(status, message, out_error);
}

fn statusText(status: u32) []const u8 {
    return switch (status) {
        wire.STATUS_INVALID_ARGUMENT => "invalid argument",
        wire.STATUS_OUT_OF_MEMORY => "out of memory",
        wire.STATUS_BUSY => "busy",
        wire.STATUS_STALE_RUN => "stale run",
        wire.STATUS_TOO_LATE => "abort too late",
        wire.STATUS_INVALID_STATE => "invalid state",
        wire.STATUS_CALLBACK_FAILED => "callback failed",
        wire.STATUS_RESOURCE_LIMIT => "resource limit",
        wire.STATUS_SKILL_CATALOG_INVALID => "Skill catalog invalid",
        wire.STATUS_STALE_CATALOG => "stale Skill catalog",
        wire.STATUS_SKILL_NOT_FOUND => "Skill not found",
        wire.STATUS_INVALID_SKILL_ARGUMENTS => "invalid Skill arguments",
        wire.STATUS_SKILL_POLICY_VIOLATION => "Skill policy violation",
        wire.STATUS_SKILL_UNAVAILABLE => "Skill unavailable",
        wire.STATUS_STALE_COMPACT => "stale compact operation",
        else => "AgentCore error",
    };
}

fn inputErrorStatus(err: anyerror) u32 {
    return if (err == error.OutOfMemory)
        wire.STATUS_OUT_OF_MEMORY
    else if (err == error.ResourceLimit)
        wire.STATUS_RESOURCE_LIMIT
    else
        wire.STATUS_INVALID_ARGUMENT;
}

fn runtimeErrorStatus(err: anyerror) u32 {
    return if (err == error.OutOfMemory)
        wire.STATUS_OUT_OF_MEMORY
    else if (err == error.UnknownBuiltinTool or err == error.UnsupportedBuiltinTool or
        err == error.DuplicateToolName or err == error.InvalidHostTool)
        wire.STATUS_INVALID_ARGUMENT
    else
        wire.STATUS_CORE_ERROR;
}

fn catalogLifecycleStatus(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
        error.RuntimeBusy, error.SessionBusy => wire.STATUS_BUSY,
        error.RuntimeUnavailable, error.InvalidSessionState => wire.STATUS_INVALID_STATE,
        error.UnsupportedFilesystem => wire.STATUS_SKILL_UNAVAILABLE,
        error.WrongRuntime, error.WrongWorkspace, error.InvalidWorkspace => wire.STATUS_INVALID_ARGUMENT,
        else => wire.STATUS_CORE_ERROR,
    };
}

fn catalogQueryStatus(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
        error.CatalogInvalid, error.InvalidScopeId => wire.STATUS_SKILL_CATALOG_INVALID,
        error.RuntimeBusy => wire.STATUS_BUSY,
        error.RuntimeUnavailable => wire.STATUS_INVALID_STATE,
        error.InvalidWorkspace => wire.STATUS_INVALID_ARGUMENT,
        else => wire.STATUS_CORE_ERROR,
    };
}

fn sessionMutationStatus(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
        error.SessionBusy, error.RuntimeBusy => wire.STATUS_BUSY,
        error.InvalidSessionState, error.SkillCatalogNotBound, error.RuntimeUnavailable => wire.STATUS_INVALID_STATE,
        error.InvalidModel,
        error.InvalidRule,
        error.InvalidSkillId,
        error.DuplicateSkillId,
        error.ForeignSkillId,
        error.WrongRuntime,
        error.WrongWorkspace,
        error.InvalidWorkspace,
        => wire.STATUS_INVALID_ARGUMENT,
        else => wire.STATUS_CORE_ERROR,
    };
}

fn compactStatus(err: anyerror) u32 {
    return switch (err) {
        error.InvalidOperationId => wire.STATUS_INVALID_ARGUMENT,
        error.StaleCompact => wire.STATUS_STALE_COMPACT,
        error.AbortTooLate => wire.STATUS_TOO_LATE,
        error.SessionBusy => wire.STATUS_BUSY,
        error.InvalidSessionState => wire.STATUS_INVALID_STATE,
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.ConcurrentMutation => wire.STATUS_CORE_ERROR,
        else => wire.STATUS_INTERNAL_ERROR,
    };
}

fn skillRunErrorStatus(self: *const AbiSession, err: anyerror) u32 {
    return switch (err) {
        error.SkillCatalogNotBound, error.InvalidSessionState => wire.STATUS_INVALID_STATE,
        error.InvalidCatalogRevision, error.InvalidSkillId => wire.STATUS_INVALID_ARGUMENT,
        error.StaleCatalog => wire.STATUS_STALE_CATALOG,
        error.SkillNotFound => wire.STATUS_SKILL_NOT_FOUND,
        error.InvalidArguments => wire.STATUS_INVALID_SKILL_ARGUMENTS,
        error.PolicyViolation, error.SkillDisabled => wire.STATUS_SKILL_POLICY_VIOLATION,
        error.SkillUnavailable, error.ModelOverrideUnavailable => wire.STATUS_SKILL_UNAVAILABLE,
        error.AgentCoreModelBindingViolation => wire.STATUS_INTERNAL_ERROR,
        error.UnsupportedFilesystem => wire.STATUS_SKILL_UNAVAILABLE,
        error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
        else => runErrorStatus(self, err),
    };
}

fn sessionCreateErrorStatus(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.InvalidWorkspaceRoot,
        error.InvalidWorkspaceHome,
        error.ToolNotInRuntime,
        error.DuplicateToolName,
        error.ShellToolDisabled,
        => wire.STATUS_INVALID_ARGUMENT,
        error.RuntimeUnavailable => wire.STATUS_INVALID_STATE,
        else => wire.STATUS_CORE_ERROR,
    };
}

fn runErrorStatus(self: *const AbiSession, err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.SessionBusy => wire.STATUS_BUSY,
        error.StaleRun => wire.STATUS_STALE_RUN,
        error.InvalidSessionState => wire.STATUS_INVALID_STATE,
        error.CallbackFailed => self.callbackFailureStatus(),
        else => wire.STATUS_CORE_ERROR,
    };
}

fn provider(code: u32) ?core.types.ProviderKind {
    return switch (code) {
        wire.PROVIDER_ANTHROPIC => .anthropic,
        wire.PROVIDER_OPENAI => .openai,
        wire.PROVIDER_GEMINI => .gemini,
        else => null,
    };
}

fn permissionMode(code: u32) ?core.types.PermissionMode {
    return switch (code) {
        wire.PERMISSION_DEFAULT => .default,
        wire.PERMISSION_ACCEPT_EDITS => .accept_edits,
        wire.PERMISSION_AUTO => .auto,
        wire.PERMISSION_DONT_ASK => .dont_ask,
        wire.PERMISSION_BYPASS => .bypass_permissions,
        else => null,
    };
}

fn shellPolicy(code: u32) ?core.agent_session.ShellPolicy {
    return switch (code) {
        wire.SHELL_DISABLED => .disabled,
        wire.SHELL_SANDBOXED => .sandboxed,
        wire.SHELL_UNRESTRICTED => .unrestricted,
        else => null,
    };
}

fn stopReason(self: *AbiSession, reason: core.agent_loop.StopReason) error{UnsupportedStopReason}!u32 {
    return switch (reason) {
        .end_turn => wire.STOP_END_TURN,
        .max_turns => wire.STOP_MAX_TURNS,
        .aborted => wire.STOP_ABORTED,
        .tool_error => wire.STOP_TOOL_ERROR,
        .api_error => wire.STOP_API_ERROR,
        .tool_loop => wire.STOP_TOOL_LOOP,
        .suspended, .backgrounded, .budget => {
            // The stateful Run has already committed Conversation changes.
            // Returning an error while leaving the facade reusable would make
            // a Host retry ambiguous and could repeat side effects.
            self.facade_poisoned.store(true, .release);
            return error.UnsupportedStopReason;
        },
    };
}

fn addMetadata(total: *u64, len: u64, total_limit: u64) error{ResourceLimit}!void {
    if (len > wire.MAX_METADATA_STRING_BYTES_V1) return error.ResourceLimit;
    total.* = std.math.add(u64, total.*, len) catch return error.ResourceLimit;
    if (total.* > total_limit) return error.ResourceLimit;
}

fn borrowedViews(
    arena: std.mem.Allocator,
    ptr: ?[*]const wire.BytesViewV1,
    count64: u64,
    metadata_total: *u64,
    metadata_limit: u64,
) ![]const []const u8 {
    if (count64 > wire.MAX_TOOL_COUNT_V1) return error.ResourceLimit;
    const count = std.math.cast(usize, count64) orelse return error.Overflow;
    if (count == 0) return &.{};
    const values = (ptr orelse return error.InvalidArgument)[0..count];
    const out = try arena.alloc([]const u8, count);
    for (values, 0..) |value, i| {
        try addMetadata(metadata_total, value.len, metadata_limit);
        out[i] = try text(value);
    }
    return out;
}

fn parseSkillSelection(
    scratch: std.mem.Allocator,
    raw: *const wire.SkillSelectionV1,
) !skill_availability.Spec {
    if (raw.struct_size != @sizeOf(wire.SkillSelectionV1) or
        !allZero(raw.reserved))
        return error.InvalidArgument;
    const default_state: skill_availability.State = switch (raw.default_state_code) {
        wire.SKILL_SELECTION_DISABLED => .disabled,
        wire.SKILL_SELECTION_ENABLED => .enabled,
        else => return error.InvalidArgument,
    };
    if (raw.exception_skill_id_count > wire.MAX_SKILL_CATALOG_SKILLS_V1)
        return error.ResourceLimit;
    const count = std.math.cast(usize, raw.exception_skill_id_count) orelse
        return error.Overflow;
    if (count == 0) {
        return .{ .default_state = default_state, .exceptions = &.{} };
    }
    const ids = (raw.exception_skill_ids orelse return error.InvalidArgument)[0..count];
    const exceptions = try scratch.alloc(skill_availability.Exception, count);
    const exception_state: skill_availability.State =
        if (default_state == .enabled) .disabled else .enabled;
    for (ids, 0..) |id, index| {
        if (id.len > 64) return error.InvalidArgument;
        const skill_id = try text(id);
        if (skill_id.len == 0) return error.InvalidArgument;
        exceptions[index] = .{
            .skill_id = skill_id,
            .state = exception_state,
        };
    }
    return .{
        .default_state = default_state,
        .exceptions = exceptions,
    };
}

fn parsePermissionRuleViews(
    scratch: std.mem.Allocator,
    ptr: ?[*]const wire.BytesViewV1,
    count64: u64,
    total_count: *u64,
    total_bytes: *u64,
) ![]const []const u8 {
    total_count.* = std.math.add(u64, total_count.*, count64) catch
        return error.ResourceLimit;
    if (total_count.* > wire.MAX_PERMISSION_RULES_V1)
        return error.ResourceLimit;
    const count = std.math.cast(usize, count64) orelse return error.Overflow;
    if (count == 0) return &.{};
    const values = (ptr orelse return error.InvalidArgument)[0..count];
    const rules = try scratch.alloc([]const u8, count);
    for (values, 0..) |value, index| {
        if (value.len == 0 or value.len > wire.MAX_PERMISSION_RULE_BYTES_V1)
            return error.InvalidRule;
        total_bytes.* = std.math.add(u64, total_bytes.*, value.len) catch
            return error.ResourceLimit;
        if (total_bytes.* > wire.MAX_PERMISSION_RULE_TOTAL_BYTES_V1)
            return error.ResourceLimit;
        rules[index] = try text(value);
    }
    return rules;
}

fn parsePermissionRuleSet(
    scratch: std.mem.Allocator,
    raw: *const wire.PermissionRuleSetV1,
) !core.permission_settings.RuleSetInput {
    if (raw.struct_size != @sizeOf(wire.PermissionRuleSetV1) or
        raw.reserved0 != 0 or !allZero(raw.reserved))
        return error.InvalidArgument;
    var total_count: u64 = 0;
    var total_bytes: u64 = 0;
    const allow = try parsePermissionRuleViews(
        scratch,
        raw.allow,
        raw.allow_count,
        &total_count,
        &total_bytes,
    );
    const ask = try parsePermissionRuleViews(
        scratch,
        raw.ask,
        raw.ask_count,
        &total_count,
        &total_bytes,
    );
    const deny = try parsePermissionRuleViews(
        scratch,
        raw.deny,
        raw.deny_count,
        &total_count,
        &total_bytes,
    );
    return .{ .allow = allow, .ask = ask, .deny = deny };
}

fn parseSchema(arena: std.mem.Allocator, encoded: []const u8) !core.json.InputSchema {
    if (encoded.len > wire.MAX_TOOL_SCHEMA_BYTES_V1) return error.ResourceLimit;
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, encoded, .{
        .duplicate_field_behavior = .@"error",
    });
    try validateSchemaDepth(root, 1);
    if (root != .object) return error.InvalidSchema;
    var fields = root.object.iterator();
    while (fields.next()) |field| {
        if (!std.mem.eql(u8, field.key_ptr.*, "type") and
            !std.mem.eql(u8, field.key_ptr.*, "properties") and
            !std.mem.eql(u8, field.key_ptr.*, "required"))
            return error.InvalidSchema;
    }
    const type_value = root.object.get("type") orelse return error.InvalidSchema;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "object")) return error.InvalidSchema;
    var schema = core.json.InputSchema{ .type = type_value.string };
    if (root.object.get("properties")) |properties| {
        if (properties != .object) return error.InvalidSchema;
        if (properties.object.count() > wire.MAX_TOOL_SCHEMA_PROPERTIES_V1) return error.ResourceLimit;
        schema.properties = properties.object;
    }
    if (root.object.get("required")) |required| {
        if (required != .array) return error.InvalidSchema;
        if (required.array.items.len > wire.MAX_TOOL_SCHEMA_PROPERTIES_V1) return error.ResourceLimit;
        const names = try arena.alloc([]const u8, required.array.items.len);
        for (required.array.items, 0..) |item, i| {
            if (item != .string) return error.InvalidSchema;
            if (schema.properties == null or schema.properties.?.get(item.string) == null)
                return error.InvalidSchema;
            for (names[0..i]) |existing| {
                if (std.mem.eql(u8, existing, item.string)) return error.InvalidSchema;
            }
            names[i] = item.string;
        }
        schema.required = names;
    }
    return schema;
}

fn validateSchemaDepth(value: std.json.Value, depth: u32) !void {
    if (depth > wire.MAX_TOOL_SCHEMA_DEPTH_V1) return error.ResourceLimit;
    switch (value) {
        .array => |array| for (array.items) |child| try validateSchemaDepth(child, depth + 1),
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| try validateSchemaDepth(entry.value_ptr.*, depth + 1);
        },
        else => {},
    }
}

fn validToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn runtimeCreate(config_ptr: ?*const wire.RuntimeConfigV1, out_runtime: ?*?*wire.RuntimeHandle, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    if (out_runtime) |out| out.* = null;
    emptyError(out_error);
    const config = config_ptr orelse return fail(wire.STATUS_INVALID_ARGUMENT, "runtime config is required", out_error);
    const out = out_runtime orelse return fail(wire.STATUS_INVALID_ARGUMENT, "out_runtime is required", out_error);
    if (config.struct_size != @sizeOf(wire.RuntimeConfigV1) or config.reserved0 != 0 or !allZero(config.reserved))
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid RuntimeConfigV1", out_error);

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var runtime_metadata: u64 = 0;
    const builtin_names = borrowedViews(
        a,
        config.builtin_tools,
        config.builtin_tool_count,
        &runtime_metadata,
        wire.MAX_RUNTIME_METADATA_BYTES_V1,
    ) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    for (builtin_names) |name| {
        if (!validToolName(name)) return fail(wire.STATUS_INVALID_ARGUMENT, "invalid builtin tool name", out_error);
    }
    if (config.host_tool_count > wire.MAX_TOOL_COUNT_V1 or
        config.builtin_tool_count > wire.MAX_TOOL_COUNT_V1 - config.host_tool_count)
        return fail(wire.STATUS_RESOURCE_LIMIT, "Runtime tool count exceeds AgentCore ABI v1 limit", out_error);
    const host_count = std.math.cast(usize, config.host_tool_count) orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "host tool count overflow", out_error);
    const host_descriptors = if (host_count == 0) &.{} else (config.host_tools orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "host_tools is required", out_error))[0..host_count];

    const self = allocator.create(AbiRuntime) catch return fail(wire.STATUS_OUT_OF_MEMORY, "allocating Runtime failed", out_error);
    var keep_self = false;
    defer if (!keep_self) allocator.destroy(self);
    self.catalogs = skill_catalog_handles.RuntimeCatalogs.init(allocator) catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    var keep_catalogs = false;
    defer if (!keep_catalogs) {
        self.catalogs.tryBeginDestroy() catch unreachable;
        self.catalogs.finishDestroy();
    };
    self.materializations = skill_materialization.Manager.init(allocator) catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    var keep_materializations = false;
    defer if (!keep_materializations) self.materializations.deinitFinal();
    self.host_tools = allocator.alloc(AbiHostTool, host_count) catch return fail(wire.STATUS_OUT_OF_MEMORY, "allocating Host tools failed", out_error);
    var keep_host_tools = false;
    defer if (!keep_host_tools) allocator.free(self.host_tools);
    const native_tools = a.alloc(core.agent_session.HostSyncTool, host_count) catch return fail(wire.STATUS_OUT_OF_MEMORY, "allocating Host definitions failed", out_error);
    for (host_descriptors, 0..) |descriptor, i| {
        if (descriptor.struct_size != @sizeOf(wire.HostToolV1) or descriptor.reserved0 != 0 or !allZero(descriptor.reserved) or descriptor.execute == null or descriptor.release_result == null)
            return fail(wire.STATUS_INVALID_ARGUMENT, "invalid HostToolV1", out_error);
        if (descriptor.input_schema_json.len > wire.MAX_TOOL_SCHEMA_BYTES_V1)
            return fail(wire.STATUS_RESOURCE_LIMIT, "Host tool schema exceeds AgentCore ABI v1 limit", out_error);
        addMetadata(&runtime_metadata, descriptor.name.len, wire.MAX_RUNTIME_METADATA_BYTES_V1) catch |err|
            return failError(inputErrorStatus(err), err, out_error);
        addMetadata(&runtime_metadata, descriptor.description.len, wire.MAX_RUNTIME_METADATA_BYTES_V1) catch |err|
            return failError(inputErrorStatus(err), err, out_error);
        addMetadata(&runtime_metadata, descriptor.input_schema_json.len, wire.MAX_RUNTIME_METADATA_BYTES_V1) catch |err|
            return failError(inputErrorStatus(err), err, out_error);
        const name = text(descriptor.name) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
        if (!validToolName(name)) return fail(wire.STATUS_INVALID_ARGUMENT, "invalid Host tool name", out_error);
        if (std.mem.eql(u8, name, model_skill_tool.TOOL_NAME))
            return fail(wire.STATUS_INVALID_ARGUMENT, "Host tool name 'Skill' is reserved by AgentCore", out_error);
        const description = text(descriptor.description) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
        const schema_json = text(descriptor.input_schema_json) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
        const schema = parseSchema(a, schema_json) catch |err| return failError(inputErrorStatus(err), err, out_error);
        self.host_tools[i] = .{ .ctx = descriptor.ctx, .execute_fn = descriptor.execute.?, .release_fn = descriptor.release_result.? };
        native_tools[i] = .{ .definition = .{ .name = name, .description = description, .input_schema = schema }, .ctx = &self.host_tools[i], .execute = AbiHostTool.execute };
    }
    self.core_runtime = core.agent_session.AgentRuntime.create(allocator, .{ .builtin_tools = builtin_names, .host_sync_tools = native_tools }) catch |err| {
        return failError(runtimeErrorStatus(err), err, out_error);
    };
    out.* = self.handle();
    keep_host_tools = true;
    keep_materializations = true;
    keep_catalogs = true;
    keep_self = true;
    return wire.STATUS_OK;
}

fn runtimeDestroy(handle: ?*wire.RuntimeHandle, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    emptyError(out_error);
    const self = runtimeFrom(handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "runtime is required", out_error));
    self.catalogs.tryBeginDestroy() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    var destroy_committed = false;
    defer if (!destroy_committed) self.catalogs.cancelDestroy();
    self.core_runtime.destroy() catch |err|
        return failError(if (err == error.RuntimeBusy) wire.STATUS_BUSY else wire.STATUS_INVALID_STATE, err, out_error);
    self.materializations.deinitFinal();
    self.catalogs.finishDestroy();
    destroy_committed = true;
    allocator.free(self.host_tools);
    allocator.destroy(self);
    return wire.STATUS_OK;
}

fn runtimeQuerySkillCatalog(
    runtime_handle: ?*wire.RuntimeHandle,
    query_ptr: ?*const wire.SkillCatalogQueryV1,
    out_catalog: ?*?*wire.SkillCatalogHandle,
    out_descriptor_json: ?*wire.OwnedBytesV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_catalog) |out| out.* = null;
    if (out_descriptor_json) |out| out.* = .{ .ptr = null, .len = 0 };
    emptyError(out_error);
    const runtime = runtimeFrom(runtime_handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "runtime is required", out_error));
    var runtime_call = runtime.catalogs.enterCall() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    defer runtime_call.deinit();
    const query = query_ptr orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "SkillCatalogQueryV1 is required", out_error);
    const catalog_out = out_catalog orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_catalog is required", out_error);
    const descriptor_out = out_descriptor_json orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_descriptor_json is required", out_error);
    if (query.struct_size != @sizeOf(wire.SkillCatalogQueryV1) or
        query.reserved0 != 0 or !allZero(query.reserved))
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid SkillCatalogQueryV1", out_error);

    var metadata: u64 = 0;
    for ([_]wire.BytesViewV1{
        query.workspace_root,
        query.workspace_home,
        query.workspace_epoch,
    }) |value| {
        addMetadata(&metadata, value.len, wire.MAX_SESSION_METADATA_BYTES_V1) catch |err|
            return failError(inputErrorStatus(err), err, out_error);
    }
    const root = text(query.workspace_root) catch |err|
        return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const home = text(query.workspace_home) catch |err|
        return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const epoch = text(query.workspace_epoch) catch |err|
        return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    if (root.len == 0)
        return fail(wire.STATUS_INVALID_ARGUMENT, "workspace_root is required", out_error);

    var workspace = skill_catalog_handles.CanonicalWorkspace.init(
        allocator,
        root,
        home,
    ) catch |err| return failError(catalogLifecycleStatus(err), err, out_error);
    defer workspace.deinit();
    const host = runtime.catalogs.queryDefault(
        runtime.materializations.io,
        &workspace,
        epoch,
        .{},
    ) catch |err| return failError(catalogQueryStatus(err), err, out_error);
    var keep_host = false;
    defer if (!keep_host) host.release() catch {};

    const descriptor = allocator.dupe(u8, host.snapshot().descriptor_json) catch
        return fail(wire.STATUS_OUT_OF_MEMORY, "allocating Skill catalog descriptor failed", out_error);
    descriptor_out.* = .{ .ptr = descriptor.ptr, .len = descriptor.len };
    catalog_out.* = catalogHandle(host);
    keep_host = true;
    return wire.STATUS_OK;
}

fn skillCatalogRelease(
    handle: ?*wire.SkillCatalogHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    emptyError(out_error);
    const catalog = catalogFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "Skill catalog is required", out_error));
    catalog.release() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    return wire.STATUS_OK;
}

fn sessionCreate(runtime_handle: ?*wire.RuntimeHandle, config_ptr: ?*const wire.SessionConfigV1, callbacks_ptr: ?*const wire.SessionCallbacksV1, out_session: ?*?*wire.SessionHandle, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    if (out_session) |out| out.* = null;
    emptyError(out_error);
    const runtime = runtimeFrom(runtime_handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "runtime is required", out_error));
    var runtime_call = runtime.catalogs.enterCall() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    defer runtime_call.deinit();
    const config = config_ptr orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session config is required", out_error);
    const callbacks = callbacks_ptr orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session callbacks are required", out_error);
    const out = out_session orelse return fail(wire.STATUS_INVALID_ARGUMENT, "out_session is required", out_error);
    if (config.struct_size != @sizeOf(wire.SessionConfigV1) or !allZero(config.reserved) or
        callbacks.struct_size != @sizeOf(wire.SessionCallbacksV1) or callbacks.reserved0 != 0 or
        !allZero(callbacks.reserved) or callbacks.on_event == null or
        (callbacks.on_ui_request != null and callbacks.release_response == null))
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid SessionConfigV1 or SessionCallbacksV1", out_error);
    const kind = provider(config.provider_kind_code) orelse return fail(wire.STATUS_INVALID_ARGUMENT, "unknown provider", out_error);
    const mode = permissionMode(config.permission_mode_code) orelse return fail(wire.STATUS_INVALID_ARGUMENT, "unknown permission mode", out_error);
    const shell = shellPolicy(config.shell_policy_code) orelse return fail(wire.STATUS_INVALID_ARGUMENT, "unknown shell policy", out_error);
    var session_metadata: u64 = 0;
    for ([_]wire.BytesViewV1{
        config.api_key,
        config.model,
        config.base_url,
        config.workspace_root,
        config.workspace_home,
    }) |value| {
        addMetadata(&session_metadata, value.len, wire.MAX_SESSION_METADATA_BYTES_V1) catch |err|
            return failError(inputErrorStatus(err), err, out_error);
    }
    const api_key = text(config.api_key) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const model = text(config.model) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const base_url = text(config.base_url) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const root = text(config.workspace_root) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const home = text(config.workspace_home) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    if (api_key.len == 0 or model.len == 0 or root.len == 0) return fail(wire.STATUS_INVALID_ARGUMENT, "api_key, model and workspace_root are required", out_error);
    var workspace = skill_catalog_handles.CanonicalWorkspace.init(
        allocator,
        root,
        home,
    ) catch |err| return failError(catalogLifecycleStatus(err), err, out_error);
    defer workspace.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const initial_selection = if (config.skill_selection) |selection|
        parseSkillSelection(scratch.allocator(), selection) catch |err|
            return failError(inputErrorStatus(err), err, out_error)
    else
        null;
    const initial_permission_rules = if (config.permission_rules) |rules|
        parsePermissionRuleSet(scratch.allocator(), rules) catch |err|
            return failError(inputErrorStatus(err), err, out_error)
    else
        null;
    const workspace_scope_id = runtime.catalogs.scopeId(&workspace) catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    var initial_binding = createInitialSkillBinding(
        runtime,
        &workspace_scope_id,
        if (config.skill_catalog) |catalog_handle|
            catalogFrom(catalog_handle)
        else
            null,
        if (initial_selection) |*selection| selection else null,
    ) catch |err| return failError(
        if (err == error.InvalidSkillBinding)
            wire.STATUS_INVALID_ARGUMENT
        else
            catalogLifecycleStatus(err),
        err,
        out_error,
    );
    var keep_binding = false;
    defer if (!keep_binding) if (initial_binding) |*binding|
        binding.deinit(&runtime.catalogs);
    const allowed = borrowedViews(
        scratch.allocator(),
        config.allowed_tools,
        config.allowed_tool_count,
        &session_metadata,
        wire.MAX_SESSION_METADATA_BYTES_V1,
    ) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    if (shell == .sandboxed) {
        sandbox_admission.validate(allocator) catch |err| return failError(
            if (err == error.OutOfMemory) wire.STATUS_OUT_OF_MEMORY else wire.STATUS_INVALID_ARGUMENT,
            err,
            out_error,
        );
    }

    const self = allocator.create(AbiSession) catch return fail(wire.STATUS_OUT_OF_MEMORY, "allocating Session failed", out_error);
    self.callbacks = callbacks.*;
    self.callback_status = .init(wire.STATUS_OK);
    self.facade_poisoned = .init(false);
    self.runtime = runtime;
    self.workspace_scope_id = workspace_scope_id;
    self.skill_binding = initial_binding;
    self.policy_root = null;
    self.call_mutex = .{};
    self.call_state = .idle;
    self.core_session = runtime.core_runtime.createSession(.{
        .provider_kind = kind,
        .api_key = api_key,
        .model = model,
        .base_url = if (base_url.len == 0) null else base_url,
        .permission_mode = mode,
        .permission_rules = initial_permission_rules,
        .workspace = .{ .root = workspace.root, .home = workspace.home, .shell = shell },
        .allowed_tools = allowed,
        .run_ui_requester = if (callbacks.on_ui_request != null) .{ .ctx = self, .requestFn = AbiSession.requestUi } else null,
        // Host tool 身份锚点 = 本 AbiSession;仅 AbiHostTool 适配层可解释此指针。
        .host_identity_ctx = self,
    }) catch |err| {
        allocator.destroy(self);
        return failError(sessionCreateErrorStatus(err), err, out_error);
    };
    self.policy_root = policy_frame.PolicyFrame.createRoot(
        allocator,
        allowed,
        shell,
        mode,
        .{
            .cwd = workspace.root,
            .project_root = workspace.root,
            .home = workspace.home,
        },
    ) catch |err| {
        // The Session has not escaped and no Run can exist yet. A destroy
        // failure here would be an internal lifecycle invariant violation,
        // not a recoverable construction error.
        self.core_session.destroy() catch unreachable;
        allocator.destroy(self);
        return failError(
            if (err == error.OutOfMemory) wire.STATUS_OUT_OF_MEMORY else wire.STATUS_INVALID_ARGUMENT,
            err,
            out_error,
        );
    };
    out.* = self.handle();
    keep_binding = true;
    return wire.STATUS_OK;
}

fn sessionDestroy(handle: ?*wire.SessionHandle, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    emptyError(out_error);
    const self = sessionFrom(handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    const runtime = self.runtime orelse
        return fail(wire.STATUS_INVALID_STATE, "Session has no owning Runtime", out_error);
    var runtime_call = runtime.catalogs.enterCall() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    defer runtime_call.deinit();
    if (!self.tryBeginDestroy()) return fail(wire.STATUS_BUSY, "Session has an active facade call", out_error);
    self.core_session.destroy() catch |err| {
        self.cancelDestroy();
        return failError(if (err == error.SessionBusy) wire.STATUS_BUSY else wire.STATUS_INVALID_STATE, err, out_error);
    };
    if (self.policy_root) |root_frame| {
        root_frame.release();
        self.policy_root = null;
    }
    if (self.skill_binding) |*binding| {
        binding.deinit(&runtime.catalogs);
        self.skill_binding = null;
    }
    allocator.destroy(self);
    return wire.STATUS_OK;
}

fn sessionSetModel(
    handle: ?*wire.SessionHandle,
    model_view: wire.BytesViewV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    emptyError(out_error);
    const self = sessionFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    if (!self.tryBeginMutation())
        return fail(wire.STATUS_BUSY, "Session has an active facade call", out_error);
    defer self.finishMutation();
    if (self.facade_poisoned.load(.acquire))
        return fail(wire.STATUS_INVALID_STATE, "Session is poisoned by a previous admitted Run failure", out_error);
    if (model_view.len == 0)
        return fail(wire.STATUS_INVALID_ARGUMENT, "model is required", out_error);
    if (model_view.len > wire.MAX_METADATA_STRING_BYTES_V1)
        return fail(wire.STATUS_RESOURCE_LIMIT, "model exceeds AgentCore ABI v1 limit", out_error);
    const model = text(model_view) catch |err|
        return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    self.core_session.setModel(model) catch |err|
        return failError(sessionMutationStatus(err), err, out_error);
    return wire.STATUS_OK;
}

fn sessionUpdateSkills(
    handle: ?*wire.SessionHandle,
    optional_catalog_handle: ?*wire.SkillCatalogHandle,
    selection_ptr: ?*const wire.SkillSelectionV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    emptyError(out_error);
    const self = sessionFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    const runtime = self.runtime orelse
        return fail(wire.STATUS_INVALID_STATE, "Session has no owning Runtime", out_error);
    var runtime_call = runtime.catalogs.enterCall() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    defer runtime_call.deinit();
    // Deliberately facade-only: Skill binding neither borrows nor mutates the
    // Core provider, and the terminal Run/compact has no remaining Skill
    // consumer while its abort call drains. The Host contract still forbids
    // this overlap; the Core cancel counter is a provider-lifetime backstop,
    // not a general-purpose concurrency oracle for unrelated facade state.
    if (!self.tryBeginMutation())
        return fail(wire.STATUS_BUSY, "Session has an active facade call", out_error);
    defer self.finishMutation();
    if (self.facade_poisoned.load(.acquire))
        return fail(wire.STATUS_INVALID_STATE, "Session is poisoned by a previous admitted Run failure", out_error);
    const selection = selection_ptr orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "Skill selection is required", out_error);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const spec = parseSkillSelection(scratch.allocator(), selection) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    self.updateSkillsAdmitted(
        runtime,
        if (optional_catalog_handle) |catalog_handle|
            catalogFrom(catalog_handle)
        else
            null,
        spec,
    ) catch |err| return failError(sessionMutationStatus(err), err, out_error);
    return wire.STATUS_OK;
}

fn sessionUpdatePermissionRules(
    handle: ?*wire.SessionHandle,
    rules_ptr: ?*const wire.PermissionRuleSetV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    emptyError(out_error);
    const self = sessionFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    if (!self.tryBeginMutation())
        return fail(wire.STATUS_BUSY, "Session has an active facade call", out_error);
    defer self.finishMutation();
    if (self.facade_poisoned.load(.acquire))
        return fail(wire.STATUS_INVALID_STATE, "Session is poisoned by a previous admitted Run failure", out_error);
    const rules = rules_ptr orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "permission rules are required", out_error);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const input = parsePermissionRuleSet(scratch.allocator(), rules) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    self.core_session.updatePermissionRules(input) catch |err|
        return failError(sessionMutationStatus(err), err, out_error);
    return wire.STATUS_OK;
}

fn sessionRunInput(
    handle: ?*wire.SessionHandle,
    run_id: u64,
    input_ptr: ?*const wire.RunInputV1,
    options_ptr: ?*const wire.RunOptionsV1,
    out_result: ?*wire.RunResultV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    // Defensive hygiene only. ABI v1 defines RunResult fields only on OK.
    if (out_result) |out| out.* = std.mem.zeroes(wire.RunResultV1);
    emptyError(out_error);
    const self = sessionFrom(handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    const runtime = self.runtime orelse
        return fail(wire.STATUS_INVALID_STATE, "Session has no owning Runtime", out_error);
    var runtime_call = runtime.catalogs.enterCall() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    defer runtime_call.deinit();
    if (!self.tryBeginRun()) return fail(wire.STATUS_BUSY, "Session has an active facade call", out_error);
    // This defer is the facade completion linearization point. Everything that
    // reads AbiSession or publishes RunResult/diagnostics happens before it;
    // after it releases the gate, sessionDestroy may immediately free `self`.
    defer self.finishRun();
    if (self.facade_poisoned.load(.acquire))
        return fail(wire.STATUS_INVALID_STATE, "Session is poisoned by a previous admitted Run failure", out_error);
    const input = input_ptr orelse return fail(wire.STATUS_INVALID_ARGUMENT, "RunInputV1 is required", out_error);
    const options = options_ptr orelse return fail(wire.STATUS_INVALID_ARGUMENT, "run options are required", out_error);
    const out = out_result orelse return fail(wire.STATUS_INVALID_ARGUMENT, "out_result is required", out_error);
    if (run_id == 0 or input.struct_size != @sizeOf(wire.RunInputV1) or
        !allZero(input.reserved) or options.struct_size != @sizeOf(wire.RunOptionsV1) or
        options.max_turns == 0 or !allZero(options.reserved))
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid run id, RunInputV1, or RunOptionsV1", out_error);
    if (options.max_turns > wire.MAX_TURNS_V1)
        return fail(wire.STATUS_RESOURCE_LIMIT, "max_turns exceeds AgentCore ABI v1 limit", out_error);
    const execution: SkillExecution = switch (input.kind_code) {
        wire.RUN_INPUT_TEXT => text_run: {
            if (!canonicalEmpty(input.skill_id) or !canonicalEmpty(input.catalog_revision) or
                !canonicalEmpty(input.arguments_json))
                return fail(wire.STATUS_INVALID_ARGUMENT, "TextInput Skill fields must be canonical empty", out_error);
            if (input.text.len > wire.MAX_PROMPT_BYTES_V1)
                return fail(wire.STATUS_RESOURCE_LIMIT, "prompt exceeds AgentCore ABI v1 limit", out_error);
            const prompt = text(input.text) catch |err|
                return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
            const text_execution = self.runTextWithBoundSkills(
                &runtime.materializations,
                run_id,
                prompt,
                options.max_turns,
            ) catch |err| {
                const status = runErrorStatus(self, err);
                if (err == error.AdmittedCleanupFailed or
                    self.core_session.isPoisoned())
                    self.facade_poisoned.store(true, .release);
                return failError(status, err, out_error);
            };
            break :text_run text_execution;
        },
        wire.RUN_INPUT_SKILL => skill_run: {
            if (!canonicalEmpty(input.text))
                return fail(wire.STATUS_INVALID_ARGUMENT, "SkillInvocation text must be canonical empty", out_error);
            if (input.skill_id.len > 64 or input.catalog_revision.len > 64)
                return fail(wire.STATUS_INVALID_ARGUMENT, "Skill identity exceeds its canonical length", out_error);
            if (input.arguments_json.len > wire.MAX_SKILL_ARGUMENT_JSON_BYTES_V1)
                return fail(wire.STATUS_RESOURCE_LIMIT, "Skill arguments exceed AgentCore ABI v1 limit", out_error);
            if (input.arguments_json.len == 0 and input.arguments_json.ptr != null)
                return fail(wire.STATUS_INVALID_SKILL_ARGUMENTS, "empty Skill arguments must be canonical", out_error);
            const skill_id = text(input.skill_id) catch |err|
                return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
            const revision = text(input.catalog_revision) catch |err|
                return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
            const arguments = text(input.arguments_json) catch |err|
                return failError(wire.STATUS_INVALID_SKILL_ARGUMENTS, err, out_error);
            if (skill_id.len == 0 or revision.len == 0)
                return fail(wire.STATUS_INVALID_ARGUMENT, "Skill id and catalog revision are required", out_error);
            break :skill_run self.runSkill(
                &runtime.materializations,
                run_id,
                revision,
                skill_id,
                arguments,
                options.max_turns,
            ) catch |err| {
                const status = skillRunErrorStatus(self, err);
                if (err == error.AdmittedCleanupFailed or
                    self.core_session.isPoisoned())
                    self.facade_poisoned.store(true, .release);
                return failError(status, err, out_error);
            };
        },
        else => return fail(wire.STATUS_INVALID_ARGUMENT, "unknown RunInputV1 kind", out_error),
    };
    const result = switch (execution) {
        .aborted => {
            out.* = .{
                .struct_size = @sizeOf(wire.RunResultV1),
                .stop_reason_code = wire.STOP_ABORTED,
                .turns = 0,
                .tool_calls = 0,
                .reserved = [_]u64{0} ** 4,
            };
            invokeTestEpilogueHook(run_id);
            return wire.STATUS_OK;
        },
        .completed => |completed| completed,
    };
    defer if (result.suspend_info) |suspend_info| suspend_info.deinit();
    invokeTestEpilogueHook(run_id);
    const stop_code = stopReason(self, result.stop_reason) catch
        return fail(wire.STATUS_INTERNAL_ERROR, "core returned a stop reason unsupported by AgentCore ABI v1", out_error);
    out.* = .{ .struct_size = @sizeOf(wire.RunResultV1), .stop_reason_code = stop_code, .turns = result.turns, .tool_calls = result.tool_calls, .reserved = [_]u64{0} ** 4 };
    return wire.STATUS_OK;
}

fn sessionAbort(handle: ?*wire.SessionHandle, run_id: u64, reason_code: u32, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    emptyError(out_error);
    const self = sessionFrom(handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    const runtime = self.runtime orelse
        return fail(wire.STATUS_INVALID_STATE, "Session has no owning Runtime", out_error);
    var runtime_call = runtime.catalogs.enterCall() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    defer runtime_call.deinit();
    if (self.facade_poisoned.load(.acquire))
        return fail(wire.STATUS_INVALID_STATE, "Session is poisoned by a previous admitted Run failure", out_error);
    const reason: core.agent_session.AbortReason = switch (reason_code) {
        wire.ABORT_USER_REQUEST => .user_interrupt,
        wire.ABORT_TIMEOUT => .timeout,
        else => return fail(wire.STATUS_INVALID_ARGUMENT, "unknown abort reason", out_error),
    };
    if (run_id == 0) return fail(wire.STATUS_INVALID_ARGUMENT, "run_id must be nonzero", out_error);
    self.core_session.abort(run_id, reason) catch |err| return failError(switch (err) {
        error.StaleRun => wire.STATUS_STALE_RUN,
        error.AbortTooLate => wire.STATUS_TOO_LATE,
        error.InvalidSessionState => wire.STATUS_INVALID_STATE,
        else => wire.STATUS_INTERNAL_ERROR,
    }, err, out_error);
    return wire.STATUS_OK;
}

fn sessionCompact(
    handle: ?*wire.SessionHandle,
    operation_id: u64,
    out_result: ?*wire.CompactResultV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_result) |out| out.* = std.mem.zeroes(wire.CompactResultV1);
    emptyError(out_error);
    const self = sessionFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    const runtime = self.runtime orelse
        return fail(wire.STATUS_INVALID_STATE, "Session has no owning Runtime", out_error);
    var runtime_call = runtime.catalogs.enterCall() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    defer runtime_call.deinit();
    if (!self.tryBeginCompact())
        return fail(wire.STATUS_BUSY, "Session has an active facade call", out_error);
    defer self.finishCompact();
    if (self.facade_poisoned.load(.acquire))
        return fail(wire.STATUS_INVALID_STATE, "Session is poisoned by a previous admitted Run failure", out_error);
    const out = out_result orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_result is required", out_error);
    const report = self.core_session.compact(operation_id, .{}) catch |err|
        return failError(compactStatus(err), err, out_error);
    out.* = .{
        .struct_size = @sizeOf(wire.CompactResultV1),
        .outcome_code = switch (report.outcome) {
            .compacted => wire.COMPACT_COMPACTED,
            .no_change => wire.COMPACT_NO_CHANGE,
            .degraded => wire.COMPACT_DEGRADED,
            .aborted => wire.COMPACT_ABORTED,
        },
        .before_context_tokens = @intCast(report.before_tokens),
        .after_context_tokens = @intCast(report.after_tokens),
        .input_tokens = report.usage.input_tokens,
        .output_tokens = report.usage.output_tokens,
        .cache_read_input_tokens = report.usage.cache_read_input_tokens,
        .cache_creation_input_tokens = report.usage.cache_creation_input_tokens,
        .reserved = [_]u64{0} ** 4,
    };
    return wire.STATUS_OK;
}

fn sessionAbortCompact(
    handle: ?*wire.SessionHandle,
    operation_id: u64,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    emptyError(out_error);
    const self = sessionFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    if (operation_id == 0)
        return fail(wire.STATUS_INVALID_ARGUMENT, "operation_id must be nonzero", out_error);
    const runtime = self.runtime orelse
        return fail(wire.STATUS_INVALID_STATE, "Session has no owning Runtime", out_error);
    var runtime_call = runtime.catalogs.enterCall() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    defer runtime_call.deinit();
    if (self.facade_poisoned.load(.acquire))
        return fail(wire.STATUS_INVALID_STATE, "Session is poisoned by a previous admitted Run failure", out_error);
    self.core_session.abortCompact(operation_id) catch |err|
        return failError(compactStatus(err), err, out_error);
    return wire.STATUS_OK;
}

fn bufferRelease(buffer: ?*wire.OwnedBytesV1) callconv(.c) void {
    const out = buffer orelse return;
    const len = std.math.cast(usize, out.len) orelse {
        out.* = .{ .ptr = null, .len = 0 };
        return;
    };
    if (len != 0) if (out.ptr) |ptr| allocator.free(ptr[0..len]);
    out.* = .{ .ptr = null, .len = 0 };
}

const api_v1 = wire.ApiV1{
    .struct_size = @sizeOf(wire.ApiV1),
    .abi_version = wire.ABI_VERSION_V1,
    .abi_revision = wire.ABI_REVISION,
    .reserved0 = 0,
    .capabilities = wire.REQUIRED_CAPABILITIES_V1,
    .runtime_create = runtimeCreate,
    .runtime_destroy = runtimeDestroy,
    .runtime_query_skill_catalog = runtimeQuerySkillCatalog,
    .skill_catalog_release = skillCatalogRelease,
    .session_create = sessionCreate,
    .session_destroy = sessionDestroy,
    .session_set_model = sessionSetModel,
    .session_update_skills = sessionUpdateSkills,
    .session_update_permission_rules = sessionUpdatePermissionRules,
    .session_run_input = sessionRunInput,
    .session_abort = sessionAbort,
    .session_compact = sessionCompact,
    .session_abort_compact = sessionAbortCompact,
    .buffer_release = bufferRelease,
    .reserved = [_]u64{0} ** 4,
};

pub export fn metask_agentcore_get_api(requested_abi: u32) callconv(.c) ?*const anyopaque {
    if (requested_abi != wire.ABI_VERSION_V1) return null;
    return @ptrCast(&api_v1);
}

test "ABI discovery is versioned" {
    try std.testing.expect(metask_agentcore_get_api(0) == null);
    const raw = metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api: *const wire.ApiV1 = @ptrCast(@alignCast(raw));
    try std.testing.expectEqual(wire.REQUIRED_CAPABILITIES_V1, api.capabilities);
}

test "UI response parser owns AskUserQuestion answers" {
    const questions = [_]core.tool_context.AskQuestion{.{ .question = "continue?", .header = "choice", .multi = false, .options = &.{.{ .label = "yes", .description = "continue" }} }};
    const req = ui_request.UiRequest{ .ask_question = &questions };
    var out: ui_request.UiResponse = undefined;
    try protocol_v1.decodeUiResponse(std.testing.allocator, &req, "{\"answers\":[{\"values\":[\"yes\"]}]}", &out);
    switch (out) {
        .answers => |answers| {
            defer std.testing.allocator.free(answers);
            defer for (answers) |answer| std.testing.allocator.free(@constCast(answer));
            try std.testing.expectEqualStrings("yes", answers[0]);
        },
        else => return error.UnexpectedResponse,
    }
}

test "UI response parser rejects an answer count mismatch" {
    const questions = [_]core.tool_context.AskQuestion{.{ .question = "continue?", .header = "choice", .multi = false, .options = &.{.{ .label = "yes", .description = "continue" }} }};
    const req = ui_request.UiRequest{ .ask_question = &questions };
    var out: ui_request.UiResponse = undefined;
    try std.testing.expectError(error.InvalidUiResponse, protocol_v1.decodeUiResponse(std.testing.allocator, &req, "{\"answers\":[]}", &out));
}

fn testHostIdent(anchor: *anyopaque) core.agent_session.HostRunIdentity {
    return .{
        .identity = .{ .session_id = core.session_id.SessionId.single, .run_id = 1 },
        .host_session_ctx = anchor,
    };
}

test "Host zero-length result must use a null pointer and preserves release descriptor on rejection" {
    const Probe = struct {
        var byte: u8 = 0;
        var releases: usize = 0;
        var released_ptr: ?[*]u8 = null;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.HOST_FAILED).* = .{ .ptr = @ptrCast(&byte), .len = 0 };
            return wire.HOST_OK;
        }

        fn release(_: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
            released_ptr = (out orelse return).ptr;
        }
    };
    Probe.releases = 0;
    Probe.released_ptr = null;
    var host = AbiHostTool{ .ctx = null, .execute_fn = Probe.execute, .release_fn = Probe.release };
    const outcome = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
    try std.testing.expect(outcome == .fatal);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    try std.testing.expect(Probe.released_ptr == @as(?[*]u8, @ptrCast(&Probe.byte)));
}

test "canonical empty Host tool results never call release" {
    const Probe = struct {
        var status: u32 = wire.HOST_OK;
        var releases: usize = 0;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.HOST_FAILED).* = .{ .ptr = null, .len = 0 };
            return status;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
        }
    };
    var host = AbiHostTool{ .ctx = null, .execute_fn = Probe.execute, .release_fn = Probe.release };

    Probe.status = wire.HOST_OK;
    Probe.releases = 0;
    const outcome = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
    const result = outcome.ok;
    try std.testing.expectEqual(@as(usize, 0), result.bytes.len);
    result.release();
    try std.testing.expectEqual(@as(usize, 0), Probe.releases);

    inline for (.{ wire.HOST_FAILED, wire.HOST_REJECTED, wire.HOST_FATAL, @as(u32, 0xffff_ffff) }) |status| {
        Probe.status = status;
        Probe.releases = 0;
        const o = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
        if (status == wire.HOST_REJECTED) {
            try std.testing.expect(o == .rejected and o.rejected == null);
        } else if (status == wire.HOST_FAILED) {
            try std.testing.expect(o == .failed and o.failed == null);
        } else {
            try std.testing.expect(o == .fatal);
        }
        try std.testing.expectEqual(@as(usize, 0), Probe.releases);
    }
}

test "Host failure detail is transferred while fatal buffers release immediately" {
    const Probe = struct {
        var status: u32 = wire.HOST_FAILED;
        var bytes = [_]u8{ 'n', 'o', 't', ' ', 'a', ' ', 'r', 'e', 's', 'u', 'l', 't' };
        var releases: usize = 0;
        var released_ptr: ?[*]u8 = null;
        var released_len: u64 = 0;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.HOST_FAILED).* = .{ .ptr = &bytes, .len = bytes.len };
            return status;
        }

        fn release(_: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
            const value = out orelse return;
            releases += 1;
            released_ptr = value.ptr;
            released_len = value.len;
        }
    };
    const OutcomeTag = std.meta.Tag(core.agent_session.HostToolOutcome);
    const cases = [_]struct {
        status: u32,
        expected: OutcomeTag,
    }{
        .{ .status = wire.HOST_FAILED, .expected = .failed },
        .{ .status = wire.HOST_REJECTED, .expected = .rejected },
        .{ .status = wire.HOST_FATAL, .expected = .fatal },
        .{ .status = 0xffff_ffff, .expected = .fatal },
    };
    var host = AbiHostTool{ .ctx = null, .execute_fn = Probe.execute, .release_fn = Probe.release };
    for (cases) |case| {
        Probe.status = case.status;
        Probe.releases = 0;
        Probe.released_ptr = null;
        Probe.released_len = 0;
        const o = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
        try std.testing.expectEqual(case.expected, std.meta.activeTag(o));
        switch (o) {
            .failed => |maybe| if (maybe) |result| {
                try std.testing.expectEqualStrings(&Probe.bytes, result.bytes);
                result.release();
            },
            .rejected => |maybe| if (maybe) |result| {
                try std.testing.expectEqualStrings(&Probe.bytes, result.bytes);
                result.release();
            },
            else => {},
        }
        try std.testing.expectEqual(@as(usize, 1), Probe.releases);
        try std.testing.expect(Probe.released_ptr == @as(?[*]u8, @ptrCast(&Probe.bytes)));
        try std.testing.expectEqual(@as(u64, Probe.bytes.len), Probe.released_len);
    }
}

test "Host failure raw detail is not capped by the encoded error payload limit" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, wire.MAX_TOOL_ERROR_PAYLOAD_BYTES_V1 + 1);
    defer a.free(bytes);
    @memset(bytes, 'x');
    const Probe = struct {
        var payload: []u8 = &.{};
        var releases: usize = 0;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.HOST_FATAL).* = .{ .ptr = payload.ptr, .len = payload.len };
            return wire.HOST_FAILED;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
        }
    };
    Probe.payload = bytes;
    Probe.releases = 0;
    var host = AbiHostTool{ .ctx = null, .execute_fn = Probe.execute, .release_fn = Probe.release };
    const outcome = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
    try std.testing.expect(outcome == .failed and outcome.failed != null);
    try std.testing.expectEqual(bytes.len, outcome.failed.?.bytes.len);
    outcome.failed.?.release();
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
}

test "Host UI descriptor ownership is independent of callback status" {
    const Probe = struct {
        var status: u32 = wire.UI_ANSWERED;
        var with_buffer: bool = false;
        var releases: usize = 0;
        const response_json = "{\"answers\":[{\"values\":[\"yes\"]}]}";

        fn request(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            const result = out orelse return wire.UI_FATAL;
            result.* = if (with_buffer)
                .{ .ptr = @constCast(response_json.ptr), .len = response_json.len }
            else
                .{ .ptr = null, .len = 0 };
            return status;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
        }
    };
    const questions = [_]core.tool_context.AskQuestion{.{ .question = "continue?", .header = "choice", .multi = false, .options = &.{.{ .label = "yes", .description = "continue" }} }};
    const request = ui_request.UiRequest{ .ask_question = &questions };
    var response: ui_request.UiResponse = undefined;
    var fake = AbiSession{
        .callbacks = .{
            .struct_size = @sizeOf(wire.SessionCallbacksV1),
            .reserved0 = 0,
            .ctx = null,
            .on_event = null,
            .on_ui_request = Probe.request,
            .release_response = Probe.release,
            .reserved = [_]u64{0} ** 4,
        },
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
    };

    Probe.status = wire.UI_ANSWERED;
    Probe.with_buffer = false;
    Probe.releases = 0;
    try std.testing.expectError(
        error.MalformedJson,
        AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expectEqual(@as(usize, 0), Probe.releases);

    Probe.status = wire.UI_UNAVAILABLE;
    Probe.with_buffer = false;
    Probe.releases = 0;
    try std.testing.expectEqual(
        ui_request.RequestOutcome.unavailable,
        try AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expectEqual(@as(usize, 0), Probe.releases);

    fake.callback_status.store(wire.STATUS_OK, .release);
    Probe.status = wire.UI_CANCELLED;
    Probe.with_buffer = true;
    Probe.releases = 0;
    try std.testing.expectError(
        error.UiCancelled,
        AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    try std.testing.expectEqual(wire.STATUS_OK, fake.callback_status.load(.acquire));

    Probe.status = wire.UI_ANSWERED;
    Probe.with_buffer = true;
    Probe.releases = 0;
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    switch (response) {
        .answers => |answers| {
            for (answers) |answer| std.testing.allocator.free(@constCast(answer));
            std.testing.allocator.free(@constCast(answers));
        },
        else => unreachable,
    }

    inline for (.{ wire.UI_UNAVAILABLE, wire.UI_FATAL, @as(u32, 0xffff_ffff) }) |status| {
        Probe.status = status;
        Probe.with_buffer = true;
        Probe.releases = 0;
        if (status == wire.UI_UNAVAILABLE) {
            try std.testing.expectEqual(
                ui_request.RequestOutcome.unavailable,
                try AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
            );
        } else {
            try std.testing.expectError(
                error.HostUiFailed,
                AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
            );
        }
        try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    }
}

test "AgentCore permission session choices use Core memory and unavailable denies once" {
    const Probe = struct {
        var status: u32 = wire.UI_ANSWERED;
        var response_json: []const u8 = "{\"permission\":\"allow_session\"}";
        var calls: usize = 0;
        var releases: usize = 0;

        fn request(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            calls += 1;
            const result = out orelse return wire.UI_FATAL;
            result.* = if (response_json.len == 0)
                .{ .ptr = null, .len = 0 }
            else
                .{ .ptr = @constCast(response_json.ptr), .len = response_json.len };
            return status;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const native_runtime = try core.agent_session.AgentRuntime.create(
        std.testing.allocator,
        .{ .builtin_tools = &.{} },
    );
    defer native_runtime.destroy() catch unreachable;
    const native_session = try native_runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = root_buffer[0..root_len] },
        .allowed_tools = &.{},
    });
    defer native_session.destroy() catch unreachable;

    const request = ui_request.UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    var response: ui_request.UiResponse = undefined;
    var fake = AbiSession{
        .callbacks = .{
            .struct_size = @sizeOf(wire.SessionCallbacksV1),
            .reserved0 = 0,
            .ctx = null,
            .on_event = null,
            .on_ui_request = Probe.request,
            .release_response = Probe.release,
            .reserved = [_]u64{0} ** 4,
        },
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = native_session,
    };

    Probe.status = wire.UI_ANSWERED;
    Probe.response_json = "{\"permission\":\"allow_session\"}";
    Probe.calls = 0;
    Probe.releases = 0;
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .allow_once);
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);

    // The second request is answered from Core-owned memory. The product
    // callback is not invoked and the core only sees an allow-once projection,
    // so its disk-persistence branch is unreachable.
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 2 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .allow_once);
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);

    var denied = AbiSession{
        .callbacks = fake.callbacks,
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = native_session,
    };
    const write_request = ui_request.UiRequest{ .permission = .{ .tool = "Write", .args = "{}" } };
    Probe.status = wire.UI_ANSWERED;
    Probe.response_json = "{\"permission\":\"deny_session\"}";
    Probe.calls = 0;
    Probe.releases = 0;
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&denied, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &write_request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .deny_once);
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&denied, .{ .session_id = .single, .run_id = 2 }, std.testing.allocator, &write_request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .deny_once);
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);

    var unavailable = AbiSession{
        .callbacks = fake.callbacks,
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = native_session,
    };
    const edit_request = ui_request.UiRequest{ .permission = .{ .tool = "Edit", .args = "{}" } };
    Probe.status = wire.UI_UNAVAILABLE;
    Probe.response_json = "";
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&unavailable, .{ .session_id = .single, .run_id = 3 }, std.testing.allocator, &edit_request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .deny_once);
    try std.testing.expectEqual(wire.STATUS_OK, unavailable.callback_status.load(.acquire));
}

test "oversized Host tool results are released exactly once" {
    const Probe = struct {
        var byte: u8 = 0;
        var releases: usize = 0;
        var released_len: u64 = 0;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.HOST_FAILED).* = .{
                .ptr = @ptrCast(&byte),
                .len = wire.MAX_HOST_TOOL_RESULT_BYTES_V1 + 1,
            };
            return wire.HOST_OK;
        }

        fn release(_: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
            released_len = (out orelse return).len;
        }
    };
    Probe.releases = 0;
    Probe.released_len = 0;
    var host = AbiHostTool{ .ctx = null, .execute_fn = Probe.execute, .release_fn = Probe.release };
    const o = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
    try std.testing.expect(o == .failed and o.failed == null);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    try std.testing.expectEqual(wire.MAX_HOST_TOOL_RESULT_BYTES_V1 + 1, Probe.released_len);
}

test "invalid UTF-8 Host tool results are released exactly once" {
    const Probe = struct {
        var bytes = [_]u8{0xff};
        var releases: usize = 0;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.HOST_FAILED).* = .{ .ptr = &bytes, .len = bytes.len };
            return wire.HOST_OK;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
        }
    };
    Probe.releases = 0;
    var host = AbiHostTool{ .ctx = null, .execute_fn = Probe.execute, .release_fn = Probe.release };
    const o = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
    try std.testing.expect(o == .failed and o.failed == null);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
}

test "oversized Host UI responses are released and classified as callback failures" {
    const Probe = struct {
        var byte: u8 = 0;
        var releases: usize = 0;

        fn request(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.UI_FATAL).* = .{
                .ptr = @ptrCast(&byte),
                .len = wire.MAX_UI_RESPONSE_BYTES_V1 + 1,
            };
            return wire.UI_ANSWERED;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
        }
    };
    Probe.releases = 0;
    const questions = [_]core.tool_context.AskQuestion{.{ .question = "continue?", .header = "choice", .multi = false, .options = &.{.{ .label = "yes", .description = "continue" }} }};
    const request = ui_request.UiRequest{ .ask_question = &questions };
    var response: ui_request.UiResponse = undefined;
    var fake = AbiSession{
        .callbacks = .{
            .struct_size = @sizeOf(wire.SessionCallbacksV1),
            .reserved0 = 0,
            .ctx = null,
            .on_event = null,
            .on_ui_request = Probe.request,
            .release_response = Probe.release,
            .reserved = [_]u64{0} ** 4,
        },
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
    };
    try std.testing.expectError(
        error.HostUiFailed,
        AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    try std.testing.expectEqual(wire.STATUS_CALLBACK_FAILED, fake.callback_status.load(.acquire));
}

test "Host schema limits reject excessive size and nesting" {
    const too_large = try std.testing.allocator.alloc(u8, @as(usize, @intCast(wire.MAX_TOOL_SCHEMA_BYTES_V1)) + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, ' ');
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ResourceLimit, parseSchema(arena.allocator(), too_large));

    var nested = std.ArrayList(u8).empty;
    defer nested.deinit(std.testing.allocator);
    try nested.appendSlice(std.testing.allocator, "{\"type\":\"object\",\"properties\":{\"x\":");
    for (0..wire.MAX_TOOL_SCHEMA_DEPTH_V1 + 1) |_| try nested.appendSlice(std.testing.allocator, "{\"x\":");
    try nested.appendSlice(std.testing.allocator, "{}");
    for (0..wire.MAX_TOOL_SCHEMA_DEPTH_V1 + 1) |_| try nested.append(std.testing.allocator, '}');
    try nested.appendSlice(std.testing.allocator, "}}");
    try std.testing.expectError(error.ResourceLimit, parseSchema(arena.allocator(), nested.items));
}

test "Host schema admission rejects ambiguous object contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(
        error.InvalidSchema,
        parseSchema(a, "{\"type\":\"object\",\"additionalProperties\":false}"),
    );
    try std.testing.expectError(
        error.InvalidSchema,
        parseSchema(a, "{\"type\":\"object\",\"required\":[\"missing\"]}"),
    );
    try std.testing.expectError(
        error.InvalidSchema,
        parseSchema(a, "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}},\"required\":[\"x\",\"x\"]}"),
    );
    try std.testing.expectError(
        error.DuplicateField,
        parseSchema(a, "{\"type\":\"object\",\"type\":\"object\"}"),
    );
}

test "provider-facing tool names use the public intersection grammar" {
    try std.testing.expect(validToolName("_"));
    try std.testing.expect(validToolName("A_9-name"));
    const max_name = "A" ++ ("x" ** 63);
    try std.testing.expectEqual(@as(usize, 64), max_name.len);
    try std.testing.expect(validToolName(max_name));

    try std.testing.expect(!validToolName(""));
    try std.testing.expect(!validToolName("1bad"));
    try std.testing.expect(!validToolName("bad:name"));
    try std.testing.expect(!validToolName("bad.name"));
    try std.testing.expect(!validToolName("A" ++ ("x" ** 64)));
}

test "Run OutOfMemory maps to the public OOM status" {
    var fake = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
    };
    try std.testing.expectEqual(wire.STATUS_OUT_OF_MEMORY, runErrorStatus(&fake, error.OutOfMemory));
}

test "unsupported Skill materialization filesystem maps to Skill unavailable" {
    var fake = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
    };
    try std.testing.expectEqual(
        wire.STATUS_SKILL_UNAVAILABLE,
        skillRunErrorStatus(&fake, error.UnsupportedFilesystem),
    );
    try std.testing.expectEqual(
        wire.STATUS_SKILL_UNAVAILABLE,
        catalogLifecycleStatus(error.UnsupportedFilesystem),
    );
}

test "AgentCore Skill model binding errors have explicit public mappings" {
    var fake = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
    };
    try std.testing.expectEqual(
        wire.STATUS_SKILL_UNAVAILABLE,
        skillRunErrorStatus(&fake, error.ModelOverrideUnavailable),
    );
    try std.testing.expectEqual(
        wire.STATUS_INTERNAL_ERROR,
        skillRunErrorStatus(&fake, error.AgentCoreModelBindingViolation),
    );
}

test "diagnostic allocation failure leaves canonical empty output" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var sentinel: u8 = 0;
    var diagnostic = wire.OwnedBytesV1{ .ptr = @ptrCast(&sentinel), .len = 1 };
    writeDiagnostic(failing.allocator(), "invalid input", &diagnostic);
    try std.testing.expect(diagnostic.ptr == null);
    try std.testing.expectEqual(@as(u64, 0), diagnostic.len);
}

test "internal continuation states poison the ABI facade" {
    var fake = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
    };
    try std.testing.expectError(error.UnsupportedStopReason, stopReason(&fake, .suspended));
    try std.testing.expect(fake.facade_poisoned.load(.acquire));
    fake.facade_poisoned.store(false, .release);
    try std.testing.expectError(error.UnsupportedStopReason, stopReason(&fake, .backgrounded));
    try std.testing.expect(fake.facade_poisoned.load(.acquire));
    fake.facade_poisoned.store(false, .release);
    try std.testing.expectError(error.UnsupportedStopReason, stopReason(&fake, .budget));
    try std.testing.expect(fake.facade_poisoned.load(.acquire));
}

test "metadata limits enforce per-field and aggregate budgets" {
    var total: u64 = 0;
    try addMetadata(&total, wire.MAX_METADATA_STRING_BYTES_V1, wire.MAX_RUNTIME_METADATA_BYTES_V1);
    try std.testing.expectEqual(wire.MAX_METADATA_STRING_BYTES_V1, total);
    try std.testing.expectError(
        error.ResourceLimit,
        addMetadata(&total, wire.MAX_METADATA_STRING_BYTES_V1 + 1, wire.MAX_RUNTIME_METADATA_BYTES_V1),
    );
    total = wire.MAX_SESSION_METADATA_BYTES_V1;
    try std.testing.expectError(
        error.ResourceLimit,
        addMetadata(&total, 1, wire.MAX_SESSION_METADATA_BYTES_V1),
    );
}

test "Session create maps caller configuration errors to invalid argument" {
    inline for (.{
        error.InvalidWorkspaceRoot,
        error.InvalidWorkspaceHome,
        error.ToolNotInRuntime,
        error.DuplicateToolName,
        error.ShellToolDisabled,
    }) |err| {
        try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, sessionCreateErrorStatus(err));
    }
    try std.testing.expectEqual(wire.STATUS_OUT_OF_MEMORY, sessionCreateErrorStatus(error.OutOfMemory));
    try std.testing.expectEqual(wire.STATUS_INVALID_STATE, sessionCreateErrorStatus(error.RuntimeUnavailable));
    try std.testing.expectEqual(wire.STATUS_CORE_ERROR, sessionCreateErrorStatus(error.Unexpected));
}

test "ABI Runtime rejects process-only built-ins as invalid input" {
    const names = [_]wire.BytesViewV1{view("TaskCreate")};
    var config = std.mem.zeroes(wire.RuntimeConfigV1);
    config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    config.builtin_tools = &names;
    config.builtin_tool_count = names.len;
    var runtime: ?*wire.RuntimeHandle = null;
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer bufferRelease(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, runtimeCreate(&config, &runtime, &diagnostic));
    try std.testing.expect(runtime == null);
}

test "ABI Runtime applies tool-name grammar to built-ins and Host tools" {
    const Probe = struct {
        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, _: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            return wire.HOST_FAILED;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {}
    };
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer bufferRelease(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;

    const invalid_builtin_names = [_]wire.BytesViewV1{view("1bad")};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &invalid_builtin_names;
    runtime_config.builtin_tool_count = invalid_builtin_names.len;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        runtimeCreate(&runtime_config, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime == null);
    bufferRelease(&diagnostic);

    var host = std.mem.zeroes(wire.HostToolV1);
    host.struct_size = @sizeOf(wire.HostToolV1);
    host.name = view("bad:name");
    host.description = view("test");
    host.input_schema_json = view("{\"type\":\"object\"}");
    host.execute = Probe.execute;
    host.release_result = Probe.release;
    runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.host_tools = @ptrCast(&host);
    runtime_config.host_tool_count = 1;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        runtimeCreate(&runtime_config, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime == null);
    bufferRelease(&diagnostic);

    host.name = view(model_skill_tool.TOOL_NAME);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        runtimeCreate(&runtime_config, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime == null);
}

test "ABI Runtime reports oversized Host schemas as resource limits" {
    const Probe = struct {
        var byte: u8 = 0;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, _: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            return wire.HOST_FAILED;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {}
    };
    var host = std.mem.zeroes(wire.HostToolV1);
    host.struct_size = @sizeOf(wire.HostToolV1);
    host.name = view("OversizedSchema");
    host.description = view("test");
    host.input_schema_json = .{
        .ptr = @ptrCast(&Probe.byte),
        .len = wire.MAX_TOOL_SCHEMA_BYTES_V1 + 1,
    };
    host.execute = Probe.execute;
    host.release_result = Probe.release;
    var config = std.mem.zeroes(wire.RuntimeConfigV1);
    config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    config.host_tools = @ptrCast(&host);
    config.host_tool_count = 1;
    var runtime: ?*wire.RuntimeHandle = null;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer bufferRelease(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_RESOURCE_LIMIT, runtimeCreate(&config, &runtime, &diagnostic));
    try std.testing.expect(runtime == null);
}

test "AbiSession model mutation delegates atomically through the shared gate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const cwd = root_buffer[0..root_len];
    const native_runtime = try core.agent_session.AgentRuntime.create(
        std.testing.allocator,
        .{ .builtin_tools = &.{} },
    );
    defer native_runtime.destroy() catch unreachable;
    const native_session = try native_runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{},
    });
    defer native_session.destroy() catch unreachable;
    try native_session.conversation.appendText(.user, "preserved");

    var session = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = native_session,
    };
    native_session.session_rules.rememberAllow("Read");
    const conversation_ptr = native_session.conversation.messages.items.ptr;

    try session.setModel("missing-model-is-locally-valid");
    try std.testing.expectEqualStrings(
        "missing-model-is-locally-valid",
        native_session.provider.provider().model(),
    );
    try std.testing.expect(native_session.conversation.messages.items.ptr == conversation_ptr);
    try std.testing.expectEqual(
        core.permission_session_rules.SessionRules.Decision.allow,
        native_session.session_rules.decisionFor("Read").?,
    );
    try std.testing.expect(session.skill_binding == null);
    try std.testing.expectEqual(AbiSession.CallState.idle, session.call_state);

    session.call_state = .running;
    try std.testing.expectError(error.SessionBusy, session.setModel("busy-model"));
    try std.testing.expectEqualStrings("missing-model-is-locally-valid", native_session.model);
    session.call_state = .idle;

    session.facade_poisoned.store(true, .release);
    try std.testing.expectError(error.InvalidSessionState, session.setModel("poisoned-model"));
    try std.testing.expectEqualStrings("missing-model-is-locally-valid", native_session.model);
}

test "AbiSession permission rule mutation delegates through the shared gate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const native_runtime = try core.agent_session.AgentRuntime.create(
        std.testing.allocator,
        .{ .builtin_tools = &.{} },
    );
    defer native_runtime.destroy() catch unreachable;
    const native_session = try native_runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = root_buffer[0..root_len] },
        .allowed_tools = &.{},
    });
    defer native_session.destroy() catch unreachable;
    native_session.session_rules.rememberAllow("Bash");

    var session = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = native_session,
    };
    try session.updatePermissionRules(.{
        .allow = &.{"Write"},
        .deny = &.{"Bash"},
    });
    try std.testing.expectEqual(
        core.permission.PermissionResult.deny,
        core.permission.checkPermission(
            &native_session.permission_ctx,
            "Bash",
            "{\"command\":\"echo ok\"}",
        ),
    );
    try std.testing.expectEqual(
        core.permission.PermissionResult.allow,
        core.permission.checkPermission(
            &native_session.permission_ctx,
            "Write",
            "{\"file_path\":\"ordinary.txt\"}",
        ),
    );
    try std.testing.expect(native_session.session_rules.isAllowed("Bash"));
    const published = native_session.permission_ctx.settings;

    try std.testing.expectError(
        error.InvalidRule,
        session.updatePermissionRules(.{ .allow = &.{"Bash("} }),
    );
    try std.testing.expect(native_session.permission_ctx.settings == published);
    try std.testing.expectEqual(AbiSession.CallState.idle, session.call_state);

    session.call_state = .running;
    try std.testing.expectError(
        error.SessionBusy,
        session.updatePermissionRules(.{}),
    );
    session.call_state = .idle;
    try std.testing.expect(native_session.permission_ctx.settings == published);

    session.facade_poisoned.store(true, .release);
    try std.testing.expectError(
        error.InvalidSessionState,
        session.updatePermissionRules(.{}),
    );
    try std.testing.expect(native_session.permission_ctx.settings == published);
}

test "Session Skill selection update is explicit atomic and selection-only" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var workspace = try skill_catalog_handles.CanonicalWorkspace.init(
        std.testing.allocator,
        root_buffer[0..root_len],
        "",
    );
    defer workspace.deinit();

    var runtime = AbiRuntime{
        .core_runtime = undefined,
        .host_tools = &.{},
        .catalogs = skill_catalog_handles.RuntimeCatalogs.initWithSecret(
            std.testing.allocator,
            [_]u8{0x41} ** 32,
        ),
        .materializations = undefined,
    };
    var other_runtime = AbiRuntime{
        .core_runtime = undefined,
        .host_tools = &.{},
        .catalogs = skill_catalog_handles.RuntimeCatalogs.initWithSecret(
            std.testing.allocator,
            [_]u8{0x42} ** 32,
        ),
        .materializations = undefined,
    };
    const scope_id = try runtime.catalogs.scopeId(&workspace);
    const first_host = try runtime.catalogs.query(io, &workspace, "first", &.{}, .{});
    const second_host = try runtime.catalogs.query(io, &workspace, "second", &.{}, .{});
    const foreign_host = try other_runtime.catalogs.query(io, &workspace, "foreign", &.{}, .{});
    defer foreign_host.release() catch unreachable;
    const all_enabled = skill_availability.Spec{
        .default_state = .enabled,
        .exceptions = &.{},
    };
    try std.testing.expect((try createInitialSkillBinding(
        &runtime,
        &scope_id,
        null,
        null,
    )) == null);
    try std.testing.expectError(error.InvalidSkillBinding, createInitialSkillBinding(
        &runtime,
        &scope_id,
        first_host,
        null,
    ));
    try std.testing.expectError(error.InvalidSkillBinding, createInitialSkillBinding(
        &runtime,
        &scope_id,
        null,
        &all_enabled,
    ));
    const initial_binding = (try createInitialSkillBinding(
        &runtime,
        &scope_id,
        first_host,
        &all_enabled,
    )).?;
    const first_cell = initial_binding.cell;
    try first_host.release();

    var session = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
        .runtime = &runtime,
        .workspace_scope_id = scope_id,
        .skill_binding = initial_binding,
    };

    session.call_state = .running;
    try std.testing.expectError(error.SessionBusy, session.updateSkills(second_host, all_enabled));
    try std.testing.expect(session.skill_binding.?.cell == first_cell);
    session.call_state = .idle;
    session.facade_poisoned.store(true, .release);
    try std.testing.expectError(
        error.InvalidSessionState,
        session.updateSkills(null, all_enabled),
    );
    session.facade_poisoned.store(false, .release);
    try std.testing.expectError(error.WrongRuntime, session.updateSkills(foreign_host, all_enabled));
    try std.testing.expect(session.skill_binding.?.cell == first_cell);

    const foreign_id = [_]u8{'f'} ** 64;
    const invalid_exceptions = [_]skill_availability.Exception{
        .{ .skill_id = &foreign_id, .state = .disabled },
    };
    try std.testing.expectError(error.ResourceLimit, session.updateSkills(null, .{
        .default_state = .enabled,
        .exceptions = &invalid_exceptions,
    }));
    try std.testing.expect(session.skill_binding.?.cell == first_cell);
    try std.testing.expectError(error.ResourceLimit, session.updateSkills(second_host, .{
        .default_state = .enabled,
        .exceptions = &invalid_exceptions,
    }));
    try std.testing.expect(session.skill_binding.?.cell == first_cell);
    try std.testing.expectEqual(@as(usize, 1), second_host.cell.references);

    try session.updateSkills(null, .{
        .default_state = .disabled,
        .exceptions = &.{},
    });
    try std.testing.expect(session.skill_binding.?.cell == first_cell);
    try std.testing.expectEqual(@as(usize, 1), first_cell.references);

    const second_cell = second_host.cell;
    try session.updateSkills(second_host, all_enabled);
    try std.testing.expect(session.skill_binding.?.cell == second_cell);
    try std.testing.expectEqual(@as(usize, 2), second_cell.references);
    try second_host.release();

    var call = try runtime.catalogs.enterCall();
    session.skill_binding.?.deinit(&runtime.catalogs);
    session.skill_binding = null;
    call.deinit();
    try std.testing.expectError(
        error.SkillCatalogNotBound,
        session.updateSkills(null, all_enabled),
    );
    try runtime.catalogs.tryBeginDestroy();
    runtime.catalogs.finishDestroy();
}

test "disabled AgentCore Skill fails before admission and materialization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const cwd = root_buffer[0..root_len];
    const native_runtime = try core.agent_session.AgentRuntime.create(
        std.testing.allocator,
        .{ .builtin_tools = &.{} },
    );
    defer native_runtime.destroy() catch unreachable;
    const native_session = try native_runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{},
    });
    defer native_session.destroy() catch unreachable;
    const root_frame = try policy_frame.PolicyFrame.createRoot(
        std.testing.allocator,
        &.{},
        .disabled,
        .default,
        .{ .cwd = cwd, .project_root = cwd, .home = cwd },
    );
    defer root_frame.release();
    var materializations = try skill_materialization.Manager.init(std.testing.allocator);
    defer materializations.deinit() catch unreachable;
    const record = skill_catalog.SkillRecord{
        .skill_id = [_]u8{'a'} ** 64,
        .invocation_name = "review",
        .definition = .{
            .name = "Review",
            .description = "Review",
            .body = "Review the target.",
            .allowed_tools = &.{},
            .disallowed_tools = &.{},
            .arguments = &.{},
            .disable_model_invocation = false,
            .context = .inline_ctx,
            .agent = "",
            .model = "",
            .shell = "bash",
            .source_path = "",
        },
        .directories = &.{},
        .files = &.{},
    };
    var snapshot_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer snapshot_arena.deinit();
    var snapshot = skill_catalog.Snapshot{
        .owner_allocator = std.testing.allocator,
        .arena = snapshot_arena,
        .scope_id = [_]u8{'c'} ** 64,
        .revision = [_]u8{'b'} ** 64,
        .health = .healthy,
        .skills = &.{record},
        .issues = &.{},
        .descriptor_json = "",
        .snapshot_bytes = 0,
        .resident_bytes = 0,
    };
    var cell = skill_catalog_handles.CatalogCell{
        .runtime = undefined,
        .snapshot = &snapshot,
        .references = 1,
        .accounted_bytes = 0,
    };
    const selection = try skill_availability.Selection.init(
        std.testing.allocator,
        &snapshot,
        .{ .default_state = .disabled, .exceptions = &.{} },
    );
    var session = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = native_session,
        .skill_binding = .{ .cell = &cell, .selection = selection },
        .policy_root = root_frame,
    };
    defer {
        session.skill_binding.?.selection.deinit();
        session.skill_binding = null;
    }
    const initial_messages = native_session.conversation.messages.items.len;

    try std.testing.expect(!model_skill_tool.Environment.hasModelInvocable(
        &snapshot,
        session.skill_binding.?.view(),
    ));
    try std.testing.expectError(error.SkillDisabled, session.runSkill(
        &materializations,
        1,
        &snapshot.revision,
        &record.skill_id,
        "{\"values\":[]}",
        1,
    ));
    try std.testing.expectEqual(
        wire.STATUS_SKILL_POLICY_VIOLATION,
        skillRunErrorStatus(&session, error.SkillDisabled),
    );
    try std.testing.expectEqual(@as(u64, 0), native_session.last_run_id);
    try std.testing.expectEqual(initial_messages, native_session.conversation.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), materializations.active_count);
}

test "Skill materialization is post-admission and pre-Conversation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const cwd = root_buffer[0..root_len];
    const native_runtime = try core.agent_session.AgentRuntime.create(
        std.testing.allocator,
        .{ .builtin_tools = &.{} },
    );
    defer native_runtime.destroy() catch unreachable;
    const native_session = try native_runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{},
    });
    defer native_session.destroy() catch unreachable;
    var session = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = native_session,
    };
    const root_frame = try policy_frame.PolicyFrame.createRoot(
        std.testing.allocator,
        &.{},
        .disabled,
        .default,
        .{ .cwd = cwd, .project_root = cwd, .home = cwd },
    );
    defer root_frame.release();
    var materializations = try skill_materialization.Manager.init(std.testing.allocator);
    defer materializations.deinit() catch unreachable;
    const record = skill_catalog.SkillRecord{
        .skill_id = [_]u8{'a'} ** 64,
        .invocation_name = "review",
        .definition = .{
            .name = "Review",
            .description = "Review",
            .body = "Review the target.",
            .allowed_tools = &.{},
            .disallowed_tools = &.{},
            .arguments = &.{},
            .disable_model_invocation = false,
            .context = .inline_ctx,
            .agent = "",
            .model = "",
            .shell = "bash",
            .source_path = "",
        },
        .directories = &.{},
        .files = &.{},
    };
    var snapshot_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer snapshot_arena.deinit();
    var snapshot = skill_catalog.Snapshot{
        .owner_allocator = std.testing.allocator,
        .arena = snapshot_arena,
        .scope_id = [_]u8{'c'} ** 64,
        .revision = [_]u8{'b'} ** 64,
        .health = .healthy,
        .skills = &.{record},
        .issues = &.{},
        .descriptor_json = "",
        .snapshot_bytes = 0,
        .resident_bytes = 0,
    };
    _ = &snapshot;
    var plan_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer plan_arena.deinit();
    const plan = skill_activation.ActivationPlan{
        .arena = plan_arena,
        .snapshot = &snapshot,
        .skill = &snapshot.skills[0],
        .arguments = &.{},
        .requires_shell = false,
        .context = .external_run_root,
        .model_selection = .inherit_parent,
    };
    const initial_messages = native_session.conversation.messages.items.len;

    materializations.max_active_bytes = 0;
    try std.testing.expectError(
        error.ResourceLimit,
        session.admitMaterializedSkill(&materializations, 1, &plan, root_frame),
    );
    try std.testing.expectEqual(initial_messages, native_session.conversation.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), materializations.active_count);

    materializations.max_active_bytes = skill_materialization.MAX_ACTIVE_BYTES;
    try std.testing.expectError(
        error.StaleRun,
        session.admitMaterializedSkill(&materializations, 1, &plan, root_frame),
    );
    var next_run_id: u64 = 2;
    const faults = [_]skill_materialization.TestFault{
        .after_reserve,
        .after_create,
        .after_write,
        .before_verify,
        .corrupt_before_verify,
    };
    for (faults) |fault| {
        materializations.setTestFault(fault);
        try std.testing.expectError(
            error.CoreError,
            session.admitMaterializedSkill(
                &materializations,
                next_run_id,
                &plan,
                root_frame,
            ),
        );
        materializations.setTestFault(null);
        try std.testing.expectEqual(
            initial_messages,
            native_session.conversation.messages.items.len,
        );
        try std.testing.expectEqual(@as(usize, 0), materializations.active_count);
        try std.testing.expectError(
            error.StaleRun,
            session.admitMaterializedSkill(
                &materializations,
                next_run_id,
                &plan,
                root_frame,
            ),
        );
        next_run_id += 1;
    }

    materializations.setTestFault(.abort_after_create);
    const aborted = try session.admitMaterializedSkill(
        &materializations,
        next_run_id,
        &plan,
        root_frame,
    );
    materializations.setTestFault(null);
    switch (aborted) {
        .aborted => {},
        .ready => return error.ExpectedAbort,
    }
    next_run_id += 1;
    try std.testing.expectEqual(initial_messages, native_session.conversation.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), materializations.active_count);

    var admission = try session.admitMaterializedSkill(
        &materializations,
        next_run_id,
        &plan,
        root_frame,
    );
    switch (admission) {
        .aborted => return error.UnexpectedAbort,
        .ready => |*ready| {
            try native_session.abort(next_run_id, .timeout);
            const completion = try ready.finishWithoutConversation();
            try std.testing.expect(completion.aborted);
        },
    }
    try std.testing.expectEqual(initial_messages, native_session.conversation.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), materializations.active_count);
}

test "typed Skill invocation record is deterministic and JSON-safe" {
    var snapshot_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer snapshot_arena.deinit();
    var plan_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer plan_arena.deinit();
    const record = skill_catalog.SkillRecord{
        .skill_id = [_]u8{'b'} ** 64,
        .invocation_name = "review:deep",
        .definition = .{
            .name = "Review",
            .description = "Review",
            .body = "Review $ARGUMENTS",
            .allowed_tools = &.{},
            .disallowed_tools = &.{},
            .arguments = &.{"target"},
            .disable_model_invocation = false,
            .context = .inline_ctx,
            .agent = "",
            .model = "",
            .shell = "bash",
            .source_path = "",
        },
        .directories = &.{},
        .files = &.{},
    };
    var snapshot = skill_catalog.Snapshot{
        .owner_allocator = std.testing.allocator,
        .arena = snapshot_arena,
        .scope_id = [_]u8{'c'} ** 64,
        .revision = [_]u8{'a'} ** 64,
        .health = .healthy,
        .skills = &.{record},
        .issues = &.{},
        .descriptor_json = "",
        .snapshot_bytes = 0,
        .resident_bytes = 0,
    };
    _ = &snapshot;
    const arguments = [_][]const u8{"src/\"quoted\"\nfile.zig"};
    const plan = skill_activation.ActivationPlan{
        .arena = plan_arena,
        .snapshot = &snapshot,
        .skill = &snapshot.skills[0],
        .arguments = &arguments,
        .requires_shell = false,
        .context = .external_run_root,
        .model_selection = .inherit_parent,
    };
    const encoded = try canonicalInvocationRecord(std.testing.allocator, &plan);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"type\":\"metask.skill-invocation/v1\",\"catalog_revision\":\"" ++
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
            "\",\"skill_id\":\"" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
            "\",\"invocation_name\":\"review:deep\",\"arguments\":{\"values\":[\"src/\\\"quoted\\\"\\nfile.zig\"]}}",
        encoded,
    );
}

test "fork depth uses the shared child-agent recursion ceiling" {
    try std.testing.expectEqual(@as(u8, 1), try ForkExecutorContext.childDepth(0));
    try std.testing.expectEqual(
        core.tool_context.MAX_AGENT_DEPTH,
        try ForkExecutorContext.childDepth(core.tool_context.MAX_AGENT_DEPTH - 1),
    );
    try std.testing.expectError(
        error.AgentDepthExceeded,
        ForkExecutorContext.childDepth(core.tool_context.MAX_AGENT_DEPTH),
    );
}
