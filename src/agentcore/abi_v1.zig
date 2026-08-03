//! Thin C ABI v1 facade over AgentRuntime and AgentSession.

const std = @import("std");
pub const session_checkpoint = @import("session_checkpoint.zig");
pub const session_authority = @import("session_authority.zig");
pub const session_permission = @import("session_permission.zig");
pub const mcp_protocol = @import("mcp_protocol.zig");
pub const mcp_catalog = @import("mcp_catalog.zig");
pub const mcp_session = @import("mcp_session.zig");
pub const mcp_checkpoint = @import("mcp_checkpoint.zig");
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
    binding: [32]u8 = [_]u8{1} ** 32,

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
    /// Populated by the Revision 6 Runtime configuration seam. Null keeps the
    /// current pre-freeze construction path MCP-free until the hard-cut DTO is
    /// published later in this revision.
    mcp_manager: ?mcp_catalog.Manager = null,

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

fn createInitialMcpView(
    runtime: *AbiRuntime,
    selectors: []const mcp_session.Selector,
    mode: mcp_session.BuildMode,
) !?mcp_session.View {
    const manager = if (runtime.mcp_manager) |*value| value else {
        if (selectors.len != 0) return error.InvalidMcpBinding;
        return null;
    };
    const snapshot = try manager.retainCurrent();
    defer snapshot.release();
    return try mcp_session.View.init(allocator, snapshot, selectors, mode);
}

const AbiSession = struct {
    const CallState = enum { idle, running, compacting, mutating, checkpointing, destroying };

    callbacks: wire.SessionCallbacksV1,
    callback_status: std.atomic.Value(u32),
    facade_poisoned: std.atomic.Value(bool),
    core_session: *core.agent_session.AgentSession,
    runtime: ?*AbiRuntime = null,
    workspace_scope_id: [64]u8 = [_]u8{0} ** 64,
    skill_binding: ?SkillBinding = null,
    mcp_view: ?mcp_session.View = null,
    /// Borrowed only while one synchronous Run is admitted. Permission uses
    /// it to resolve the model-facing alias back to canonical MCP identity.
    active_mcp_view: ?*const mcp_session.View = null,
    /// Null only in narrow unit-test fakes. Every live Session created through
    /// the ABI owns exactly one immutable baseline frame.
    policy_root: ?*policy_frame.PolicyFrame = null,
    call_mutex: sync.Mutex = .{},
    call_state: CallState = .idle,
    checkpoint_generation: u64 = 0,
    policy_generation: u64 = 1,
    policy_fingerprint: session_permission.PolicyFingerprint = [_]u8{0} ** 32,
    catalog_generation: u64 = 0,
    logical_origin: session_authority.LogicalOrigin = .fresh,
    restore_health: session_authority.RestoreHealth = .complete,
    invalidated_skill_authority: u32 = 0,
    invalidated_permission_rules: u32 = 0,
    invalidated_mcp_bindings: u32 = 0,
    permission_state: session_permission.State = .{
        .allocator = allocator,
        .policy_generation = 1,
    },
    permission_audit: ?session_permission.AuditTrail = null,
    permission_request_sequence: u64 = 0,
    pending_permission: ?PendingPermission = null,
    last_terminal_kind: session_checkpoint.TerminalKind = .none,
    last_terminal_id: u64 = 0,

    const PendingPermission = struct {
        tool_namespace: session_permission.ToolNamespace,
        tool_name: []const u8,
        binding: [32]u8,
        arguments_digest: session_permission.ArgumentsDigest,
        source: session_permission.DecisionSource,

        fn matches(
            self: PendingPermission,
            tool: session_permission.ToolIdentity,
            digest: session_permission.ArgumentsDigest,
        ) bool {
            return self.tool_namespace == tool.namespace and
                std.mem.eql(u8, self.tool_name, tool.name) and
                std.mem.eql(u8, &self.binding, &tool.binding) and
                std.mem.eql(u8, &self.arguments_digest, &digest);
        }
    };

    fn permissionDecisionOverride(
        raw: *anyopaque,
        tool_name: []const u8,
        arguments_json: []const u8,
        imported: core.permission.ImportedPermissionDecision,
    ) ?core.permission.PermissionResult {
        const self: *AbiSession = @ptrCast(@alignCast(raw));
        self.pending_permission = null;
        if (self.active_mcp_view) |mcp_bound| {
            if (mcp_bound.findModelTool(tool_name) != null and
                !mcp_bound.validatesInvocation(tool_name, arguments_json))
                return .deny;
        }
        const tool = self.permissionToolIdentity(tool_name) catch return .deny;
        const digest = session_permission.digestCanonicalArguments(
            allocator,
            arguments_json,
            .{},
        ) catch return .deny;
        var match_context = self.core_session.permission_ctx.match_ctx;
        if (match_context.alloc == null)
            match_context.alloc = self.core_session.permission_ctx.allocator;
        const explicit: session_permission.ExplicitAction = if (self.core_session.permission_ctx.settings != null)
            session_permission.evaluateExplicit(
                self.core_session.permission_ctx.settings,
                &match_context,
                tool_name,
                arguments_json,
            )
        else switch (imported) {
            .undecided => .undecided,
            .deny => .deny,
            .ask => .ask,
            .allow => .allow,
        };
        const permission_mode = self.core_session.permission_ctx.modeValue();
        const external_fallback: session_permission.Decision = if (tool.namespace == .builtin)
            .ask
        else switch (permission_mode) {
            .plan, .dont_ask => .deny,
            .bypass_permissions, .bypass => .allow,
            .default, .accept_edits, .auto, .prompt => .ask,
        };
        var result = self.permission_state.decide(
            tool,
            digest,
            explicit,
            .{ .decision = external_fallback, .source = .mode_fallback },
        ) catch return .deny;
        const suppress_prompt = permission_mode == .dont_ask and
            result.decision == .ask;
        if (suppress_prompt) result.decision = .deny;
        if (result.decision == .ask) self.pending_permission = .{
            .tool_namespace = tool.namespace,
            .tool_name = tool.name,
            .binding = tool.binding,
            .arguments_digest = digest,
            .source = result.source,
        };
        if (result.used_session_rule or
            result.source == .explicit_allow or
            result.source == .explicit_deny or
            suppress_prompt)
        {
            self.recordPermissionDecision(
                tool_name,
                tool,
                arguments_json,
                digest,
                result,
            ) catch
                return .deny;
        }
        if (suppress_prompt) return .deny;
        // Built-ins retain the Core's read/edit/risk classification. Host and
        // MCP identities are intentionally unknown to that product-level
        // classifier, so AgentCore must finish their conservative mode
        // fallback here instead of letting an unknown alias become read-only.
        if (result.source == .mode_fallback and tool.namespace == .builtin)
            return null;
        return switch (result.decision) {
            .deny => .deny,
            .ask => .ask,
            .allow => .allow,
        };
    }

    fn permissionToolIdentity(
        self: *AbiSession,
        tool_name: []const u8,
    ) session_permission.Error!session_permission.ToolIdentity {
        if (self.active_mcp_view) |mcp_bound|
            if (mcp_bound.findModelTool(tool_name)) |entry|
                return entry.permissionIdentity();
        // The model-facing Skill tool is AgentCore-owned but materialized
        // outside Core's immutable Runtime catalog. It remains once-only until
        // its selected catalog revision is incorporated into a Session rule
        // candidate during the Permission checkpoint child.
        if (std.mem.eql(u8, tool_name, model_skill_tool.TOOL_NAME))
            return .{ .namespace = .builtin, .name = model_skill_tool.TOOL_NAME };
        const entry = self.core_session.tools.find(tool_name) orelse
            return error.InvalidIdentity;
        return switch (entry.executor) {
            .builtin => if (session_permission.isKnownBuiltin(tool_name))
                .{ .namespace = .builtin, .name = entry.definition.name }
            else
                error.InvalidIdentity,
            .host_sync => |host| blk: {
                const abi_tool: *AbiHostTool = @ptrCast(@alignCast(host.ctx));
                break :blk .{
                    .namespace = .host,
                    .name = entry.definition.name,
                    .binding = abi_tool.binding,
                };
            },
        };
    }

    fn copyPermissionToolCallId(
        self: *AbiSession,
        output_allocator: std.mem.Allocator,
        tool_name: []const u8,
        arguments_json: []const u8,
    ) session_permission.Error![]u8 {
        self.core_session.conversation.lockSnapshot();
        defer self.core_session.conversation.unlockSnapshot();
        const messages = self.core_session.conversation.messages.items;
        if (messages.len == 0) return error.InvalidIdentity;
        const latest = messages[messages.len - 1];
        var match: ?[]const u8 = null;
        for (latest.blocks) |block| switch (block) {
            .tool_use => |tool_use| {
                if (!std.mem.eql(u8, tool_use.name, tool_name) or
                    !std.mem.eql(u8, tool_use.input, arguments_json)) continue;
                // The old UiRequest omits tool_call_id. Ambiguous identical
                // calls must fail closed; guessing would bind approval to the
                // wrong operation. The R6 public DTO removes this scan.
                if (match != null) return error.InvalidIdentity;
                match = tool_use.id;
            },
            else => {},
        };
        const found = match orelse return error.InvalidIdentity;
        if (found.len == 0 or found.len > session_permission.MAX_TOOL_CALL_ID_BYTES)
            return error.InvalidIdentity;
        return output_allocator.dupe(u8, found) catch error.OutOfMemory;
    }

    fn recordPermissionDecision(
        self: *AbiSession,
        model_tool_name: []const u8,
        tool: session_permission.ToolIdentity,
        arguments_json: []const u8,
        digest: session_permission.ArgumentsDigest,
        result: session_permission.DecisionResult,
    ) session_permission.Error!void {
        const audit = if (self.permission_audit) |*value| value else return;
        const run_id = self.core_session.active_run_id;
        if (run_id == 0) return error.InvalidIdentity;
        const tool_call_id = try self.copyPermissionToolCallId(
            allocator,
            model_tool_name,
            arguments_json,
        );
        defer allocator.free(tool_call_id);
        try audit.append(.{
            .decision = result.decision,
            .source = result.source,
            .matched_rule_id = result.matched_rule_id,
            .session_id = self.core_session.session_id,
            .run_id = run_id,
            .tool_call_id = tool_call_id,
            .tool = tool,
            .arguments_digest = digest,
            .policy_generation = self.policy_generation,
            .used_session_rule = result.used_session_rule,
        });
    }

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
        return switch (req.*) {
            .permission => |permission| self.requestPermissionUi(
                identity,
                response_allocator,
                permission.tool,
                permission.args,
                out,
            ),
            else => self.requestOtherUi(
                identity,
                response_allocator,
                req,
                out,
            ),
        };
    }

    fn requestPermissionUi(
        self: *AbiSession,
        identity: core.agent_session.RunIdentity,
        response_allocator: std.mem.Allocator,
        tool_name: []const u8,
        arguments_json: []const u8,
        out: *ui_request.UiResponse,
    ) anyerror!ui_request.RequestOutcome {
        const tool = self.permissionToolIdentity(tool_name) catch |err| {
            self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
            return err;
        };
        const digest = session_permission.digestCanonicalArguments(
            response_allocator,
            arguments_json,
            .{},
        ) catch |err| {
            self.recordCallbackStatus(if (err == error.OutOfMemory)
                wire.STATUS_OUT_OF_MEMORY
            else
                wire.STATUS_CALLBACK_FAILED);
            return err;
        };
        if (self.pending_permission) |pending| {
            if (!pending.matches(tool, digest)) {
                self.pending_permission = null;
                self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                return error.HostUiFailed;
            }
        }
        const tool_call_id = self.copyPermissionToolCallId(
            response_allocator,
            tool_name,
            arguments_json,
        ) catch |err| {
            self.recordCallbackStatus(if (err == error.OutOfMemory)
                wire.STATUS_OUT_OF_MEMORY
            else
                wire.STATUS_CALLBACK_FAILED);
            return err;
        };
        defer response_allocator.free(tool_call_id);

        if (self.permission_request_sequence == std.math.maxInt(u64)) {
            self.recordCallbackStatus(wire.STATUS_RESOURCE_LIMIT);
            return error.ResourceLimit;
        }
        self.permission_request_sequence += 1;
        const candidate = try session_permission.deriveRuleCandidate(
            tool,
            digest,
        );
        const request_id = try session_permission.deriveRequestId(
            identity.session_id,
            identity.run_id,
            tool_call_id,
            tool,
            digest,
            self.policy_generation,
            self.permission_request_sequence,
        );
        const request = session_permission.PermissionRequest{
            .session_id = identity.session_id,
            .run_id = identity.run_id,
            .tool_call_id = tool_call_id,
            .request_id = request_id,
            .tool = tool,
            .arguments_digest = digest,
            .policy_generation = self.policy_generation,
            .candidate = candidate,
        };
        const prompt_source: session_permission.DecisionSource = if (self.pending_permission != null and
            self.pending_permission.?.matches(tool, digest))
            self.pending_permission.?.source
        else
            .core_safety;
        self.pending_permission = null;
        const encoding_options = session_permission.CallbackEncodingOptions{
            .allow_session_response = prompt_source != .explicit_ask and
                prompt_source != .core_safety,
        };

        // `dont_ask` is a Session mode contract, not a UI preference. Core
        // safety prompts are produced before the AgentCore override seam, so
        // close that path here without calling the Host.
        if (self.core_session.permission_ctx.modeValue() == .dont_ask) {
            try self.recordPermissionCallback(request, .answered, .deny_once);
            out.* = .{ .permission = .deny_once };
            return .answered;
        }

        const callback = self.callbacks.on_ui_request orelse {
            try self.recordPermissionCallback(
                request,
                .unavailable,
                null,
            );
            return .unavailable;
        };
        const release_fn = self.callbacks.release_response orelse return error.HostUiFailed;
        const request_json = session_permission.encodeCallbackRequest(
            response_allocator,
            request,
            arguments_json,
            encoding_options,
        ) catch |err| {
            self.recordCallbackStatus(if (err == error.OutOfMemory)
                wire.STATUS_OUT_OF_MEMORY
            else
                wire.STATUS_INTERNAL_ERROR);
            return err;
        };
        defer response_allocator.free(request_json);
        var response = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
        const run = self.runContext(&identity);
        const status = callback(self.callbacks.ctx, &run, view(request_json), &response);
        defer if (hasReleaseToken(response)) release_fn(self.callbacks.ctx, &response);
        if (!canonicalOwned(response)) {
            self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
            try self.recordPermissionCallback(
                request,
                .contract_failure,
                null,
            );
            return error.HostUiFailed;
        }
        return switch (status) {
            wire.UI_UNAVAILABLE => blk: {
                if (response.len != 0) {
                    self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                    try self.recordPermissionCallback(
                        request,
                        .contract_failure,
                        null,
                    );
                    return error.HostUiFailed;
                }
                try self.recordPermissionCallback(
                    request,
                    .unavailable,
                    null,
                );
                break :blk .unavailable;
            },
            wire.UI_CANCELLED => {
                if (response.len != 0) {
                    self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                    try self.recordPermissionCallback(
                        request,
                        .contract_failure,
                        null,
                    );
                    return error.HostUiFailed;
                }
                try self.recordPermissionCallback(
                    request,
                    .user_cancelled,
                    null,
                );
                return error.UiCancelled;
            },
            wire.UI_ANSWERED => blk: {
                if (response.len > wire.MAX_UI_RESPONSE_BYTES_V1) {
                    self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                    try self.recordPermissionCallback(
                        request,
                        .contract_failure,
                        null,
                    );
                    return error.HostUiFailed;
                }
                const bytes = ownedSlice(response) catch |err| {
                    self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                    try self.recordPermissionCallback(
                        request,
                        .contract_failure,
                        null,
                    );
                    return err;
                };
                const permission_response = session_permission.decodeCallbackResponse(
                    response_allocator,
                    bytes,
                    request,
                    encoding_options,
                ) catch |err| {
                    self.recordCallbackStatus(if (err == error.OutOfMemory)
                        wire.STATUS_OUT_OF_MEMORY
                    else
                        wire.STATUS_CALLBACK_FAILED);
                    try self.recordPermissionCallback(
                        request,
                        .contract_failure,
                        null,
                    );
                    return err;
                };
                switch (permission_response) {
                    .allow_session, .deny_session => {
                        const rule_candidate = candidate orelse {
                            self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                            try self.recordPermissionCallback(
                                request,
                                .contract_failure,
                                null,
                            );
                            return error.HostUiFailed;
                        };
                        _ = self.permission_state.remember(
                            permission_response,
                            rule_candidate,
                            self.policy_generation,
                        ) catch |err| {
                            self.recordCallbackStatus(if (err == error.OutOfMemory)
                                wire.STATUS_OUT_OF_MEMORY
                            else if (err == error.ResourceLimit)
                                wire.STATUS_RESOURCE_LIMIT
                            else
                                wire.STATUS_CALLBACK_FAILED);
                            return err;
                        };
                    },
                    .allow_once, .deny_once => {},
                }
                out.* = .{ .permission = switch (permission_response) {
                    .allow_once, .allow_session => .allow_once,
                    .deny_once, .deny_session => .deny_once,
                } };
                try self.recordPermissionCallback(
                    request,
                    .answered,
                    permission_response,
                );
                break :blk .answered;
            },
            else => {
                self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                try self.recordPermissionCallback(
                    request,
                    .contract_failure,
                    null,
                );
                return error.HostUiFailed;
            },
        };
    }

    fn requestOtherUi(
        self: *AbiSession,
        identity: core.agent_session.RunIdentity,
        response_allocator: std.mem.Allocator,
        req: *const ui_request.UiRequest,
        out: *ui_request.UiResponse,
    ) anyerror!ui_request.RequestOutcome {
        const callback = self.callbacks.on_ui_request orelse return .unavailable;
        const release_fn = self.callbacks.release_response orelse
            return error.HostUiFailed;
        const request_json = protocol_v1.encodeUiRequest(
            response_allocator,
            req,
        ) catch |err| {
            self.recordCallbackStatus(if (err == error.OutOfMemory)
                wire.STATUS_OUT_OF_MEMORY
            else
                wire.STATUS_INTERNAL_ERROR);
            return err;
        };
        defer response_allocator.free(request_json);
        var response = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
        const run = self.runContext(&identity);
        const status = callback(
            self.callbacks.ctx,
            &run,
            view(request_json),
            &response,
        );
        defer if (hasReleaseToken(response))
            release_fn(self.callbacks.ctx, &response);
        if (!canonicalOwned(response)) {
            self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
            return error.HostUiFailed;
        }
        return switch (status) {
            wire.UI_UNAVAILABLE => .unavailable,
            wire.UI_CANCELLED => error.UiCancelled,
            wire.UI_ANSWERED => blk: {
                if (response.len > wire.MAX_UI_RESPONSE_BYTES_V1) {
                    self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                    return error.HostUiFailed;
                }
                const bytes = ownedSlice(response) catch |err| {
                    self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                    return err;
                };
                protocol_v1.decodeUiResponse(
                    response_allocator,
                    req,
                    bytes,
                    out,
                ) catch |err| {
                    self.recordCallbackStatus(if (err == error.OutOfMemory)
                        wire.STATUS_OUT_OF_MEMORY
                    else
                        wire.STATUS_CALLBACK_FAILED);
                    return err;
                };
                break :blk .answered;
            },
            else => {
                self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                return error.HostUiFailed;
            },
        };
    }

    fn recordPermissionCallback(
        self: *AbiSession,
        request: session_permission.PermissionRequest,
        callback_outcome: session_permission.CallbackOutcome,
        response: ?session_permission.Response,
    ) session_permission.Error!void {
        const audit = if (self.permission_audit) |*value| value else return;
        const decision: session_permission.Decision = switch (response orelse
            .deny_once) {
            .allow_once, .allow_session => .allow,
            .deny_once, .deny_session => .deny,
        };
        try audit.append(.{
            .decision = decision,
            .source = .callback,
            .session_id = request.session_id,
            .run_id = request.run_id,
            .tool_call_id = request.tool_call_id,
            .request_id = request.request_id,
            .tool = request.tool,
            .arguments_digest = request.arguments_digest,
            .policy_generation = request.policy_generation,
            .callback_outcome = callback_outcome,
            .response = response,
        });
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

    fn tryBeginCheckpoint(self: *AbiSession) bool {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        if (self.call_state != .idle) return false;
        self.call_state = .checkpointing;
        return true;
    }

    fn finishCheckpoint(self: *AbiSession) void {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        std.debug.assert(self.call_state == .checkpointing);
        self.call_state = .idle;
    }

    fn commitCheckpointGeneration(self: *AbiSession, generation: u64) void {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        std.debug.assert(self.call_state == .checkpointing);
        std.debug.assert(generation > self.checkpoint_generation);
        self.checkpoint_generation = generation;
    }

    fn recordTerminal(
        self: *AbiSession,
        kind: session_checkpoint.TerminalKind,
        operation_id: u64,
    ) void {
        std.debug.assert(kind == .run or kind == .compact);
        std.debug.assert(operation_id != 0);
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        self.last_terminal_kind = kind;
        self.last_terminal_id = operation_id;
    }

    fn terminalForCheckpoint(
        self: *const AbiSession,
        lease: *const core.agent_session.CheckpointLease,
    ) struct { kind: session_checkpoint.TerminalKind, id: u64 } {
        switch (self.last_terminal_kind) {
            .run => if (self.last_terminal_id == lease.last_run_id)
                return .{ .kind = .run, .id = self.last_terminal_id },
            .compact => if (self.last_terminal_id == lease.last_compact_id)
                return .{ .kind = .compact, .id = self.last_terminal_id },
            .none, .budget_exhausted, .resource_limit => {},
        }
        // Direct Core tests may have advanced a Session without traversing the
        // facade. Prefer the Run anchor because it preserves strict Run-ID
        // continuation; compact identity remains independently encoded.
        if (lease.last_run_id != 0)
            return .{ .kind = .run, .id = lease.last_run_id };
        if (lease.last_compact_id != 0)
            return .{ .kind = .compact, .id = lease.last_compact_id };
        return .{ .kind = .none, .id = 0 };
    }

    fn exportCheckpoint(
        self: *AbiSession,
        limits: session_checkpoint.Limits,
        sink: session_checkpoint.Sink,
    ) !session_checkpoint.ExportReport {
        if (self.facade_poisoned.load(.acquire))
            return error.InvalidSessionState;
        const runtime = self.runtime orelse return error.InvalidSessionState;
        var runtime_call = try runtime.catalogs.enterCall();
        defer runtime_call.deinit();
        if (!self.tryBeginCheckpoint()) return error.SessionBusy;
        defer self.finishCheckpoint();

        var lease = try self.core_session.snapshotCommitted();
        defer lease.deinit();
        const binding_snapshot = if (self.skill_binding) |*binding|
            binding.snapshot()
        else
            null;
        const binding_selection = if (self.skill_binding) |*binding|
            &binding.selection
        else
            null;
        const skill_state = try session_authority.encodeSkillState(
            allocator,
            binding_snapshot,
            binding_selection,
        );
        defer allocator.free(skill_state);
        const permission_state = try session_authority.encodePermissionState(
            allocator,
            self.core_session.permission_ctx.modeValue(),
            &self.permission_state,
            self.policy_fingerprint,
        );
        defer allocator.free(permission_state);
        const mcp_state = try mcp_checkpoint.encodeView(
            allocator,
            if (self.mcp_view) |*mcp_bound| mcp_bound else null,
        );
        defer allocator.free(mcp_state);
        const next_generation = std.math.add(
            u64,
            self.checkpoint_generation,
            1,
        ) catch return error.ResourceLimit;
        const terminal = self.terminalForCheckpoint(&lease);
        const report = try session_checkpoint.exportToSink(.{
            .session_id = lease.session_id,
            .checkpoint_generation = next_generation,
            .last_run_id = lease.last_run_id,
            .last_compact_id = lease.last_compact_id,
            .terminal_kind = terminal.kind,
            .terminal_id = terminal.id,
            .model = lease.model,
            .conversation = lease.conversation,
            .policy_generation = self.policy_generation,
            .catalog_generation = self.catalog_generation,
            .authority = .{
                .skill = skill_state,
                .permission = permission_state,
                .mcp = mcp_state,
            },
        }, limits, sink);
        self.commitCheckpointGeneration(next_generation);
        return report;
    }

    fn describe(
        self: *AbiSession,
        description_allocator: std.mem.Allocator,
    ) !session_authority.SessionDescription {
        const runtime = self.runtime orelse return error.InvalidSessionState;
        var runtime_call = try runtime.catalogs.enterCall();
        defer runtime_call.deinit();
        if (!self.tryBeginCheckpoint()) return error.SessionBusy;
        defer self.finishCheckpoint();
        var lease = try self.core_session.snapshotCommitted();
        defer lease.deinit();
        const model = description_allocator.dupe(u8, lease.model) catch
            return error.OutOfMemory;
        errdefer description_allocator.free(model);
        return .{
            .allocator = description_allocator,
            .session_id = lease.session_id,
            .origin = self.logical_origin,
            .lifecycle = .idle,
            .registered = true,
            .last_run_id = lease.last_run_id,
            .last_compact_id = lease.last_compact_id,
            .checkpoint_generation = self.checkpoint_generation,
            .policy_generation = self.policy_generation,
            .catalog_generation = self.catalog_generation,
            .model = model,
            .conversation_messages = @intCast(lease.conversation.messages.items.len),
            .compact_boundary = @intCast(lease.conversation.compact_boundary),
            .skill_revision = if (self.skill_binding) |*binding|
                binding.snapshot().revision
            else
                null,
            .restore_health = self.restore_health,
            .invalidated_skill_authority = self.invalidated_skill_authority,
            .invalidated_permission_rules = self.invalidated_permission_rules,
            .invalidated_mcp_bindings = self.invalidated_mcp_bindings,
        };
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

    /// AgentCore Session mutation admitted through the common idle gate.
    fn setModel(self: *AbiSession, model: []const u8) !void {
        if (self.facade_poisoned.load(.acquire))
            return error.InvalidSessionState;
        if (!self.tryBeginMutation()) return error.SessionBusy;
        defer self.finishMutation();
        try self.core_session.setModel(model);
    }

    /// Host rules are compiled by the canonical Core parser/matcher; the
    /// AgentCore facade adds lifecycle admission and authority invalidation.
    fn updatePermissionRules(
        self: *AbiSession,
        input: core.permission_settings.RuleSetInput,
    ) !void {
        if (self.facade_poisoned.load(.acquire))
            return error.InvalidSessionState;
        if (!self.tryBeginMutation()) return error.SessionBusy;
        defer self.finishMutation();
        try self.updatePermissionRulesAdmitted(input);
    }

    fn updatePermissionRulesAdmitted(
        self: *AbiSession,
        input: core.permission_settings.RuleSetInput,
    ) !void {
        const next_generation = std.math.add(
            u64,
            self.policy_generation,
            1,
        ) catch return error.ResourceLimit;
        const definitions = self.core_session.tools.definitions;
        const tool_names = try allocator.alloc([]const u8, definitions.len);
        defer allocator.free(tool_names);
        for (definitions, tool_names) |definition, *name|
            name.* = definition.name;
        const next_fingerprint = try session_permission.computePolicyFingerprint(
            allocator,
            self.core_session.permission_ctx.modeValue(),
            input,
            .{
                .root = self.core_session.workspace.root,
                .home = self.core_session.workspace.home,
                .shell = self.core_session.workspace.shell,
            },
            tool_names,
        );
        try self.core_session.updatePermissionRules(input);
        self.permission_state.replaceGeneration(next_generation) catch
            unreachable;
        self.policy_generation = next_generation;
        self.policy_fingerprint = next_fingerprint;
        self.pending_permission = null;
    }

    /// Replace the Session's filtered MCP catalog only at the common idle
    /// mutation boundary. The new immutable Runtime snapshot and PolicyFrame
    /// are fully prepared before publication; active Runs therefore keep the
    /// generation they admitted with.
    fn updateMcpView(
        self: *AbiSession,
        selectors: []const mcp_session.Selector,
        mode: mcp_session.BuildMode,
    ) !void {
        if (self.facade_poisoned.load(.acquire)) return error.InvalidSessionState;
        if (!self.tryBeginMutation()) return error.SessionBusy;
        defer self.finishMutation();
        const runtime_owner = self.runtime orelse return error.InvalidSessionState;
        const manager = if (runtime_owner.mcp_manager) |*value| value else return error.InvalidMcpBinding;
        const snapshot = try manager.retainCurrent();
        defer snapshot.release();
        var replacement = try mcp_session.View.init(
            allocator,
            snapshot,
            selectors,
            mode,
        );
        var replacement_live = true;
        defer if (replacement_live) replacement.deinit();

        const base_definitions = self.core_session.tools.definitions;
        const names = try allocator.alloc(
            []const u8,
            base_definitions.len + replacement.entries.len,
        );
        defer allocator.free(names);
        for (base_definitions, names[0..base_definitions.len]) |definition, *name|
            name.* = definition.name;
        for (replacement.entries, names[base_definitions.len..]) |entry, *name|
            name.* = entry.model_name;
        const next_root = try policy_frame.PolicyFrame.createRoot(
            allocator,
            names,
            self.core_session.workspace.shell,
            self.core_session.permission_ctx.modeValue(),
            self.core_session.permission_ctx.match_ctx,
        );
        var next_root_live = true;
        defer if (next_root_live) next_root.release();

        var previous_view = self.mcp_view;
        const previous_root = self.policy_root;
        self.mcp_view = replacement;
        replacement_live = false;
        self.policy_root = next_root;
        next_root_live = false;
        self.catalog_generation = self.mcp_view.?.catalog_generation;
        self.pending_permission = null;

        const resolver_context = RestorePermissionResolver{
            .runtime = runtime_owner,
            .allowed_tools = names[0..base_definitions.len],
            .mcp_view = &self.mcp_view.?,
        };
        const stale_grants = self.permission_state.invalidateUnresolvable(
            .mcp,
            resolver_context.interface(),
        );
        self.invalidated_mcp_bindings +|= stale_grants +| self.mcp_view.?.invalidated;
        if (stale_grants != 0 or self.mcp_view.?.invalidated != 0)
            self.restore_health = .degraded;
        if (previous_root) |root| root.release();
        if (previous_view) |*old| old.deinit();
    }

    /// Internal typed-Skill entry. All validation before
    /// `admitMaterializedSkill` is side-effect free.
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
        const binding: ?*SkillBinding = if (self.skill_binding) |*value| value else null;
        const has_model_skill = if (binding) |value|
            materializations.supportsExactFileModes() and
                model_skill_tool.Environment.hasModelInvocable(
                    value.snapshot(),
                    value.view(),
                )
        else
            false;
        const has_mcp = if (self.mcp_view) |*mcp_bound| mcp_bound.entries.len != 0 else false;
        if (!has_model_skill and !has_mcp) {
            return .{ .completed = try self.core_session.runText(
                run_id,
                prompt,
                max_turns,
                .{ .ctx = self, .emit = AbiSession.emit },
            ) };
        }
        const identity = core.agent_session.RunIdentity{
            .session_id = self.core_session.session_id,
            .run_id = run_id,
        };
        var mcp_environment: ?mcp_session.Environment = if (has_mcp)
            try mcp_session.Environment.init(
                allocator,
                &self.mcp_view.?,
                self.core_session.tools.definitions,
                self.core_session.tools.dispatcher(),
                null,
            )
        else
            null;
        var mcp_environment_live = mcp_environment != null;
        defer if (mcp_environment_live) mcp_environment.?.deinit();

        var skill_environment: ?model_skill_tool.Environment = if (has_model_skill) blk: {
            const root_frame = self.policy_root orelse return error.InvalidSessionState;
            const value = binding.?;
            break :blk try model_skill_tool.Environment.init(.{
                .allocator = allocator,
                .session = self.core_session,
                .materializations = materializations,
                .snapshot = value.snapshot(),
                .availability = value.view(),
                .identity = identity,
                .base_frame = root_frame,
                .abort = &self.core_session.abort_signal,
                .event_sink = .{ .ctx = self, .emit = AbiSession.emit },
                .max_turns = max_turns,
                .base_surface = if (mcp_environment) |*environment|
                    environment.surface()
                else
                    null,
                .base_policy = if (mcp_environment) |*environment|
                    environment.executionPolicy()
                else
                    null,
            });
        } else null;
        var skill_environment_live = skill_environment != null;
        defer if (skill_environment_live) skill_environment.?.deinit() catch {};

        var admitted = try self.core_session.admitRun(
            run_id,
            .{ .ctx = self, .emit = AbiSession.emit },
        );
        self.active_mcp_view = if (has_mcp) &self.mcp_view.? else null;
        defer self.active_mcp_view = null;
        const result = (if (skill_environment) |*environment|
            admitted.runUserMessagesWithToolSurface(
                &.{prompt},
                max_turns,
                environment.executionPolicy(),
                environment.surface(),
            )
        else if (mcp_environment) |*environment|
            admitted.runUserMessagesWithToolSurface(
                &.{prompt},
                max_turns,
                environment.executionPolicy(),
                environment.surface(),
            )
        else
            unreachable) catch |run_error| {
            const callback_failed = if (skill_environment) |*environment|
                environment.callbackFailed()
            else
                false;
            var cleanup_failed = false;
            if (skill_environment) |*environment| environment.deinit() catch {
                cleanup_failed = true;
            };
            skill_environment_live = false;
            if (mcp_environment) |*environment| environment.deinit();
            mcp_environment_live = false;
            if (cleanup_failed) return error.AdmittedCleanupFailed;
            if (callback_failed) return error.CallbackFailed;
            return run_error;
        };
        if (skill_environment) |*environment| environment.deinit() catch {
            skill_environment_live = false;
            return error.AdmittedCleanupFailed;
        };
        skill_environment_live = false;
        if (mcp_environment) |*environment| environment.deinit();
        mcp_environment_live = false;
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
        const has_mcp = if (self.facade.mcp_view) |*mcp_bound| mcp_bound.entries.len != 0 else false;
        var mcp_environment: ?mcp_session.Environment = if (has_mcp)
            mcp_session.Environment.init(
                allocator,
                &self.facade.mcp_view.?,
                self.admitted.session.tools.definitions,
                self.admitted.session.tools.dispatcher(),
                self.activation.frame.executionPolicy(),
            ) catch |environment_error| {
                _ = try self.finishWithoutConversation();
                return environment_error;
            }
        else
            null;
        var mcp_environment_live = mcp_environment != null;
        defer if (mcp_environment_live) mcp_environment.?.deinit();
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
                    .base_surface = if (mcp_environment) |*mcp_env|
                        mcp_env.surface()
                    else
                        null,
                    .base_policy = if (mcp_environment) |*mcp_env|
                        mcp_env.executionPolicy()
                    else
                        null,
                }) catch |environment_error| {
                    _ = try self.finishWithoutConversation();
                    return environment_error;
                }
            else
                null;
        var environment_live = environment != null;
        defer if (environment_live) environment.?.deinit() catch {};
        self.facade.active_mcp_view = if (has_mcp) &self.facade.mcp_view.? else null;
        defer self.facade.active_mcp_view = null;
        const result = (if (environment) |*env|
            self.admitted.runUserMessagesWithToolSurface(
                &.{ invocation_record, body_record },
                max_turns,
                env.executionPolicy(),
                env.surface(),
            )
        else if (mcp_environment) |*mcp_env|
            self.admitted.runUserMessagesWithToolSurface(
                &.{ invocation_record, body_record },
                max_turns,
                mcp_env.executionPolicy(),
                mcp_env.surface(),
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
            if (mcp_environment) |*mcp_env| mcp_env.deinit();
            mcp_environment_live = false;
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
        if (mcp_environment) |*mcp_env| mcp_env.deinit();
        mcp_environment_live = false;
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
        const has_mcp = if (self.facade.mcp_view) |*mcp_bound| mcp_bound.entries.len != 0 else false;
        var mcp_environment: ?mcp_session.Environment = if (has_mcp)
            try mcp_session.Environment.init(
                output_allocator,
                &self.facade.mcp_view.?,
                self.session.tools.definitions,
                self.session.tools.dispatcher(),
                self.activation.frame.executionPolicy(),
            )
        else
            null;
        var mcp_environment_live = mcp_environment != null;
        defer if (mcp_environment_live) mcp_environment.?.deinit();
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
                    .base_surface = if (mcp_environment) |*mcp_env|
                        mcp_env.surface()
                    else
                        null,
                    .base_policy = if (mcp_environment) |*mcp_env|
                        mcp_env.executionPolicy()
                    else
                        null,
                })
            else
                null;
        var environment_live = environment != null;
        defer if (environment_live) environment.?.deinit() catch {};
        const definitions = if (environment) |*env|
            env.definitions
        else if (mcp_environment) |*mcp_env|
            mcp_env.definitions
        else
            self.session.tools.definitions;
        const dispatcher = if (environment) |*env|
            env.surface().dispatcher
        else if (mcp_environment) |*mcp_env|
            mcp_env.surface().dispatcher
        else
            self.session.tools.dispatcher();
        const execution_policy = if (environment) |*env|
            env.executionPolicy()
        else if (mcp_environment) |*mcp_env|
            mcp_env.executionPolicy()
        else
            self.activation.frame.executionPolicy();

        self.facade.active_mcp_view = if (has_mcp) &self.facade.mcp_view.? else null;
        defer self.facade.active_mcp_view = null;
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
                .system_prompt = "You are a subagent. Complete the task and return a concise final answer.\n",
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
        if (mcp_environment) |*mcp_env| {
            mcp_env.deinit();
            mcp_environment_live = false;
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
    self.mcp_manager = null;
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
        const binding = session_permission.deriveHostBinding(
            a,
            name,
            schema_json,
        ) catch |err| return failError(inputErrorStatus(err), err, out_error);
        self.host_tools[i] = .{
            .ctx = descriptor.ctx,
            .execute_fn = descriptor.execute.?,
            .release_fn = descriptor.release_result.?,
            .binding = binding,
        };
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
    if (self.mcp_manager) |*manager| manager.deinit();
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

const SessionBuildConfig = struct {
    callbacks: wire.SessionCallbacksV1,
    provider_kind: core.types.ProviderKind,
    api_key: []const u8,
    model: []const u8,
    base_url: ?[]const u8,
    permission_mode: core.types.PermissionMode,
    permission_rules: ?core.permission_settings.RuleSetInput,
    workspace: core.agent_session.WorkspaceConfig,
    allowed_tools: []const []const u8,
    workspace_scope_id: [64]u8,
    skill_binding: ?SkillBinding,
    restored: ?*const session_checkpoint.Decoded = null,
    skill_summary: session_authority.AuthoritySummary = .{},
    permission_reconciliation: ?*session_permission.Reconciliation = null,
    mcp_selectors: []const mcp_session.Selector = &.{},
    mcp_build_mode: mcp_session.BuildMode = .fresh,
    /// Non-null pointer transfers its optional value on every path. This lets
    /// restore deliberately preserve an absent historical MCP binding even
    /// when the current Runtime has a catalog.
    mcp_view_transfer: ?*?mcp_session.View = null,
    mcp_invalidated_without_view: u32 = 0,
};

const RestoreHostConfig = struct {
    callbacks: wire.SessionCallbacksV1,
    provider_kind: core.types.ProviderKind,
    api_key: []const u8,
    base_url: ?[]const u8,
    permission_mode: core.types.PermissionMode,
    permission_rules: ?core.permission_settings.RuleSetInput,
    workspace: core.agent_session.WorkspaceConfig,
    allowed_tools: []const []const u8,
    workspace_scope_id: [64]u8,
};

const InternalRestoreResult = struct {
    session: *AbiSession,
    report: session_authority.RestoreReport,
};

const RestorePermissionResolver = struct {
    runtime: *AbiRuntime,
    allowed_tools: []const []const u8,
    mcp_view: ?*const mcp_session.View,

    fn interface(self: *const RestorePermissionResolver) session_permission.ExternalIdentityResolver {
        return .{ .ctx = self, .is_resolvable_fn = isResolvable };
    }

    fn isResolvable(raw: *const anyopaque, tool: session_permission.ToolIdentity) bool {
        const self: *const RestorePermissionResolver = @ptrCast(@alignCast(raw));
        return switch (tool.namespace) {
            .builtin => false,
            .host => blk: {
                if (!containsName(self.allowed_tools, tool.name)) break :blk false;
                const entry = self.runtime.core_runtime.catalog.find(tool.name) orelse break :blk false;
                break :blk switch (entry.executor) {
                    .builtin => false,
                    .host_sync => |host| inner: {
                        const abi_tool: *AbiHostTool = @ptrCast(@alignCast(host.ctx));
                        break :inner std.mem.eql(u8, &abi_tool.binding, &tool.binding);
                    },
                };
            },
            .mcp => blk: {
                const bound = self.mcp_view orelse break :blk false;
                for (bound.entries) |entry|
                    if (session_permission.ToolIdentity.eql(entry.permissionIdentity(), tool))
                        break :blk true;
                break :blk false;
            },
        };
    }
};

fn containsName(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, needle)) return true;
    return false;
}

/// Construct a facade only from canonical, already-bounded inputs. The caller
/// retains `skill_binding` on failure and transfers it on success.
fn buildAbiSession(
    runtime: *AbiRuntime,
    config: SessionBuildConfig,
) !*AbiSession {
    var initial_mcp_view = if (config.mcp_view_transfer) |source| blk: {
        const transferred = source.*;
        source.* = null;
        break :blk transferred;
    } else try createInitialMcpView(
        runtime,
        config.mcp_selectors,
        config.mcp_build_mode,
    );
    var keep_mcp_view = false;
    defer if (!keep_mcp_view) if (initial_mcp_view) |*mcp_bound| mcp_bound.deinit();
    const mcp_tool_count = if (initial_mcp_view) |*mcp_bound| mcp_bound.entries.len else 0;
    const authority_tool_names = try allocator.alloc(
        []const u8,
        config.allowed_tools.len + mcp_tool_count,
    );
    defer allocator.free(authority_tool_names);
    @memcpy(authority_tool_names[0..config.allowed_tools.len], config.allowed_tools);
    if (initial_mcp_view) |*mcp_bound| {
        for (mcp_bound.entries, authority_tool_names[config.allowed_tools.len..]) |entry, *name|
            name.* = entry.model_name;
    }
    const mcp_invalidated = std.math.add(
        u32,
        config.mcp_invalidated_without_view,
        if (initial_mcp_view) |*mcp_bound| mcp_bound.invalidated else 0,
    ) catch return error.ResourceLimit;
    const policy_fingerprint = try session_permission.computePolicyFingerprint(
        allocator,
        config.permission_mode,
        config.permission_rules,
        config.workspace,
        config.allowed_tools,
    );
    const policy_generation: u64 = if (config.permission_reconciliation) |value|
        value.policy_generation
    else
        1;
    if (policy_generation == 0) return error.PermissionStateUnsupported;
    var permission_state = if (config.permission_reconciliation) |value|
        value.takeState()
    else
        try session_permission.State.init(allocator, policy_generation);
    var keep_permission_state = false;
    defer if (!keep_permission_state) permission_state.deinit();
    var permission_audit = try session_permission.AuditTrail.init(allocator);
    var keep_permission_audit = false;
    defer if (!keep_permission_audit) permission_audit.deinit();
    const self = try allocator.create(AbiSession);
    errdefer allocator.destroy(self);
    self.* = .{
        .callbacks = config.callbacks,
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
        .runtime = runtime,
        .workspace_scope_id = config.workspace_scope_id,
        .skill_binding = config.skill_binding,
        .mcp_view = initial_mcp_view,
        .checkpoint_generation = if (config.restored) |decoded|
            decoded.descriptor.checkpoint_generation
        else
            0,
        .policy_generation = policy_generation,
        .policy_fingerprint = policy_fingerprint,
        .catalog_generation = if (initial_mcp_view) |*mcp_bound|
            mcp_bound.catalog_generation
        else
            0,
        .logical_origin = if (config.restored == null) .fresh else .restored,
        .restore_health = if ((switch (config.skill_summary.disposition) {
            .not_bound, .restored => false,
            .narrowed, .unavailable, .changed => true,
        }) or (config.permission_reconciliation != null and
            (config.permission_reconciliation.?.invalidated != 0 or
                !config.permission_reconciliation.?.fingerprint_compatible)) or
            mcp_invalidated != 0)
            .degraded
        else
            .complete,
        .invalidated_skill_authority = config.skill_summary.invalidated,
        .invalidated_permission_rules = if (config.permission_reconciliation) |value|
            value.invalidated
        else
            0,
        .invalidated_mcp_bindings = mcp_invalidated,
        .permission_state = permission_state,
        .permission_audit = permission_audit,
        .last_terminal_kind = if (config.restored) |decoded|
            decoded.descriptor.terminal_kind
        else
            .none,
        .last_terminal_id = if (config.restored) |decoded|
            decoded.descriptor.terminal_id
        else
            0,
    };
    keep_permission_state = true;
    keep_permission_audit = true;
    keep_mcp_view = true;
    errdefer {
        if (self.mcp_view) |*mcp_bound| mcp_bound.deinit();
        if (self.permission_audit) |*audit| audit.deinit();
        self.permission_state.deinit();
    }

    const core_config = core.agent_session.SessionConfig{
        .provider_kind = config.provider_kind,
        .api_key = config.api_key,
        .model = config.model,
        .base_url = config.base_url,
        .permission_mode = config.permission_mode,
        .permission_rules = config.permission_rules,
        .workspace = config.workspace,
        .allowed_tools = config.allowed_tools,
        // Always attach the AgentCore requester. A missing Host callback is a
        // typed `unavailable` outcome with provenance, never an implicit
        // process-stdin fallback or an answered deny.
        .run_ui_requester = .{ .ctx = self, .requestFn = AbiSession.requestUi },
        .host_identity_ctx = self,
    };
    self.core_session = if (config.restored) |decoded|
        try runtime.core_runtime.createRestoredSession(core_config, .{
            .session_id = decoded.descriptor.session_id,
            .last_run_id = decoded.descriptor.last_run_id,
            .last_compact_id = decoded.descriptor.last_compact_id,
            .conversation = @constCast(&decoded.conversation),
        })
    else
        try runtime.core_runtime.createSession(core_config);
    errdefer self.core_session.destroy() catch unreachable;
    // AgentCore owns its Session rules. Disconnect the product-level
    // name-only memory and install the optional, otherwise inert shared seam.
    self.core_session.permission_ctx.session_rules = null;
    self.core_session.permission_ctx.decision_override = .{
        .ctx = self,
        .decideFn = AbiSession.permissionDecisionOverride,
    };

    self.policy_root = try policy_frame.PolicyFrame.createRoot(
        allocator,
        authority_tool_names,
        config.workspace.shell,
        config.permission_mode,
        .{
            .cwd = config.workspace.root,
            .project_root = config.workspace.root,
            .home = config.workspace.home,
        },
    );
    return self;
}

/// Internal Revision 6 restore seam. `current_skill_binding` is consumed on
/// every path after decoding succeeds. It represents current Host authority,
/// while the checkpoint selection is intersected as the historical ceiling.
fn restoreCheckpoint(
    runtime: *AbiRuntime,
    config: RestoreHostConfig,
    current_skill_binding: *?SkillBinding,
    source: session_checkpoint.Source,
    limits: session_checkpoint.Limits,
) !InternalRestoreResult {
    var runtime_call = try runtime.catalogs.enterCall();
    defer runtime_call.deinit();
    var decoded = try session_checkpoint.decodeFromSource(
        allocator,
        source,
        limits,
    );
    defer decoded.deinit();
    var restored_permission = try session_authority.decodePermissionState(
        allocator,
        decoded.permission_state,
    );
    defer restored_permission.deinit();
    if (restored_permission.policy_generation !=
        decoded.descriptor.policy_generation)
        return error.PermissionStateUnsupported;
    var restored_mcp_state = try mcp_checkpoint.decode(allocator, decoded.mcp_state);
    defer if (restored_mcp_state) |*state| state.deinit();
    if (restored_mcp_state) |*state| {
        if (state.catalog_generation != decoded.descriptor.catalog_generation)
            return error.McpStateUnsupported;
    } else if (decoded.descriptor.catalog_generation != 0) {
        return error.McpStateUnsupported;
    }
    var restored_mcp_view: ?mcp_session.View = null;
    defer if (restored_mcp_view) |*mcp_bound| mcp_bound.deinit();
    var mcp_invalidated_without_view: u32 = 0;
    if (restored_mcp_state) |*state| {
        const selectors = try state.selectors(allocator);
        defer allocator.free(selectors);
        if (runtime.mcp_manager) |*manager| {
            const current_snapshot = manager.retainCurrent() catch |err| switch (err) {
                error.NotRefreshed => null,
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidConfig, error.ResourceLimit => return error.ResourceLimit,
            };
            if (current_snapshot) |snapshot| {
                defer snapshot.release();
                restored_mcp_view = try mcp_session.View.init(
                    allocator,
                    snapshot,
                    selectors,
                    .restore_degraded,
                );
            } else {
                mcp_invalidated_without_view = @intCast(state.entries.len);
            }
        } else {
            mcp_invalidated_without_view = @intCast(state.entries.len);
        }
    }
    const restored_mcp_count: u32 = if (restored_mcp_view) |*mcp_bound|
        @intCast(mcp_bound.entries.len)
    else
        0;
    const current_fingerprint = try session_permission.computePolicyFingerprint(
        allocator,
        config.permission_mode,
        config.permission_rules,
        config.workspace,
        config.allowed_tools,
    );
    const resolver = RestorePermissionResolver{
        .runtime = runtime,
        .allowed_tools = config.allowed_tools,
        .mcp_view = if (restored_mcp_view) |*mcp_bound| mcp_bound else null,
    };
    var permission_reconciliation = try session_permission.reconcileCheckpointWithResolver(
        allocator,
        &restored_permission,
        config.permission_mode,
        current_fingerprint,
        config.allowed_tools,
        resolver.interface(),
    );
    defer permission_reconciliation.deinit();
    var restored_skill = try session_authority.decodeSkillState(
        allocator,
        decoded.skill_state,
    );
    defer if (restored_skill) |*state| state.deinit();

    var binding = current_skill_binding.*;
    current_skill_binding.* = null;
    var keep_binding = false;
    defer if (!keep_binding) if (binding) |*value|
        value.deinit(&runtime.catalogs);
    var reconciliation = try session_authority.reconcileSkillState(
        allocator,
        if (restored_skill) |*state| state else null,
        if (binding) |*value| value.snapshot() else null,
        if (binding) |*value| &value.selection else null,
    );
    defer reconciliation.deinit();
    if (reconciliation.takeSelection()) |replacement| {
        const value = if (binding) |*existing| existing else return error.InvalidState;
        var previous = value.selection;
        value.selection = replacement;
        previous.deinit();
    } else if (binding) |*value| {
        value.deinit(&runtime.catalogs);
        binding = null;
    }

    const skill_summary = reconciliation.summary();
    const self = try buildAbiSession(runtime, .{
        .callbacks = config.callbacks,
        .provider_kind = config.provider_kind,
        .api_key = config.api_key,
        .model = decoded.model,
        .base_url = config.base_url,
        .permission_mode = config.permission_mode,
        .permission_rules = config.permission_rules,
        .workspace = config.workspace,
        .allowed_tools = config.allowed_tools,
        .workspace_scope_id = config.workspace_scope_id,
        .skill_binding = binding,
        .restored = &decoded,
        .skill_summary = skill_summary,
        .permission_reconciliation = &permission_reconciliation,
        .mcp_view_transfer = &restored_mcp_view,
        .mcp_invalidated_without_view = mcp_invalidated_without_view,
    });
    keep_binding = true;
    return .{
        .session = self,
        .report = .{
            .health = self.restore_health,
            .session_id = self.core_session.session_id,
            .checkpoint_generation = self.checkpoint_generation,
            .policy_generation = self.policy_generation,
            .catalog_generation = self.catalog_generation,
            .skill = skill_summary,
            .permission_rules_restored = permission_reconciliation.restored,
            .permission_rules_invalidated = permission_reconciliation.invalidated,
            .mcp_bindings_restored = restored_mcp_count,
            .mcp_bindings_invalidated = self.invalidated_mcp_bindings,
        },
    };
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

    const self = buildAbiSession(runtime, .{
        .callbacks = callbacks.*,
        .provider_kind = kind,
        .api_key = api_key,
        .model = model,
        .base_url = if (base_url.len == 0) null else base_url,
        .permission_mode = mode,
        .permission_rules = initial_permission_rules,
        .workspace = .{ .root = workspace.root, .home = workspace.home, .shell = shell },
        .allowed_tools = allowed,
        .workspace_scope_id = workspace_scope_id,
        .skill_binding = initial_binding,
    }) catch |err| {
        return failError(
            if (err == error.OutOfMemory)
                wire.STATUS_OUT_OF_MEMORY
            else if (err == error.ResourceLimit)
                wire.STATUS_RESOURCE_LIMIT
            else if (err == error.InvalidPolicy)
                wire.STATUS_INVALID_ARGUMENT
            else
                sessionCreateErrorStatus(err),
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
    if (self.mcp_view) |*mcp_bound| {
        mcp_bound.deinit();
        self.mcp_view = null;
    }
    if (self.permission_audit) |*audit| audit.deinit();
    self.permission_state.deinit();
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
    self.updatePermissionRulesAdmitted(input) catch |err|
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
    self.recordTerminal(.run, run_id);
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
    self.recordTerminal(.compact, operation_id);
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

const TestCheckpointBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    read_offset: usize = 0,

    fn write(raw: *anyopaque, part: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try self.bytes.appendSlice(self.allocator, part);
    }

    fn read(raw: *anyopaque, out: []u8) anyerror!usize {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.read_offset == self.bytes.items.len) return 0;
        const count = @min(out.len, self.bytes.items.len - self.read_offset);
        @memcpy(
            out[0..count],
            self.bytes.items[self.read_offset..][0..count],
        );
        self.read_offset += count;
        return count;
    }

    fn sink(self: *@This()) session_checkpoint.Sink {
        return .{ .ctx = self, .write_fn = write };
    }

    fn source(self: *@This()) session_checkpoint.Source {
        self.read_offset = 0;
        return .{ .ctx = self, .read_fn = read };
    }

    fn clear(self: *@This()) void {
        self.bytes.clearRetainingCapacity();
        self.read_offset = 0;
    }

    fn deinit(self: *@This()) void {
        self.bytes.deinit(self.allocator);
    }
};

const TestEventSink = struct {
    fn emit(
        _: *anyopaque,
        _: core.session_id.SessionId,
        _: u64,
        _: core.protocol.ui_event.CoreEvent,
    ) bool {
        return true;
    }

    fn sink(ctx: *u8) core.agent_session.EventSink {
        return .{ .ctx = ctx, .emit = emit };
    }
};

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

test "Revision 6 AgentCore Permission callback binds grants and preserves typed unavailable" {
    const Probe = struct {
        var status: u32 = wire.UI_ANSWERED;
        var permission: []const u8 = "allow_session";
        var calls: usize = 0;
        var releases: usize = 0;
        var response_buffer: [1024]u8 = undefined;
        var last_request: [4096]u8 = undefined;
        var last_request_len: usize = 0;

        fn request(_: ?*anyopaque, _: ?*const wire.RunContextV1, request_view: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            calls += 1;
            const result = out orelse return wire.UI_FATAL;
            if (status != wire.UI_ANSWERED) {
                result.* = .{ .ptr = null, .len = 0 };
                return status;
            }
            const request_len = std.math.cast(usize, request_view.len) orelse
                return wire.UI_FATAL;
            const request_bytes = if (request_len == 0)
                ""
            else
                (request_view.ptr orelse return wire.UI_FATAL)[0..request_len];
            if (request_bytes.len > last_request.len) return wire.UI_FATAL;
            @memcpy(last_request[0..request_bytes.len], request_bytes);
            last_request_len = request_bytes.len;
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                std.heap.c_allocator,
                request_bytes,
                .{},
            ) catch return wire.UI_FATAL;
            defer parsed.deinit();
            const root = switch (parsed.value) {
                .object => |object| object,
                else => return wire.UI_FATAL,
            };
            const request_id = switch (root.get("request_id") orelse
                return wire.UI_FATAL) {
                .string => |value| value,
                else => return wire.UI_FATAL,
            };
            const generation = switch (root.get("policy_generation") orelse
                return wire.UI_FATAL) {
                .integer => |value| value,
                else => return wire.UI_FATAL,
            };
            const encoded = if (std.mem.endsWith(u8, permission, "_session")) blk: {
                const candidate_value = root.get("candidate") orelse
                    return wire.UI_FATAL;
                const candidate = switch (candidate_value) {
                    .object => |object| object,
                    else => return wire.UI_FATAL,
                };
                const rule_id = switch (candidate.get("rule_id") orelse
                    return wire.UI_FATAL) {
                    .string => |value| value,
                    else => return wire.UI_FATAL,
                };
                break :blk std.fmt.bufPrint(
                    &response_buffer,
                    "{{\"permission\":\"{s}\",\"request_id\":\"{s}\",\"policy_generation\":{d},\"rule_id\":\"{s}\"}}",
                    .{ permission, request_id, generation, rule_id },
                ) catch return wire.UI_FATAL;
            } else std.fmt.bufPrint(
                &response_buffer,
                "{{\"permission\":\"{s}\",\"request_id\":\"{s}\",\"policy_generation\":{d}}}",
                .{ permission, request_id, generation },
            ) catch return wire.UI_FATAL;
            result.* = .{ .ptr = encoded.ptr, .len = encoded.len };
            return status;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
        }
    };
    const ToolCall = struct {
        fn append(
            session: *core.agent_session.AgentSession,
            id: []const u8,
            name: []const u8,
            input: []const u8,
        ) !void {
            const a = session.allocator;
            const id_owned = try a.dupe(u8, id);
            errdefer a.free(id_owned);
            const name_owned = try a.dupe(u8, name);
            errdefer a.free(name_owned);
            const input_owned = try a.dupe(u8, input);
            errdefer a.free(input_owned);
            const blocks = try a.alloc(core.message.Block, 1);
            errdefer a.free(blocks);
            blocks[0] = .{ .tool_use = .{
                .id = id_owned,
                .name = name_owned,
                .input = input_owned,
            } };
            try session.conversation.append(.{
                .role = .assistant,
                .blocks = blocks,
            });
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const native_runtime = try core.agent_session.AgentRuntime.create(
        std.testing.allocator,
        .{ .builtin_tools = &.{ "Bash", "Write", "Edit" } },
    );
    defer native_runtime.destroy() catch unreachable;
    const native_session = try native_runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{
            .root = root_buffer[0..root_len],
            .shell = .unrestricted,
        },
        .allowed_tools = &.{ "Bash", "Write", "Edit" },
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
    defer fake.permission_state.deinit();

    Probe.status = wire.UI_ANSWERED;
    Probe.permission = "allow_session";
    Probe.calls = 0;
    Probe.releases = 0;
    try ToolCall.append(native_session, "call-allow", "Bash", "{}");
    try std.testing.expect(
        AbiSession.permissionDecisionOverride(
            &fake,
            "Bash",
            "{}",
            .undecided,
        ) == null,
    );
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&fake, .{
            .session_id = native_session.session_id,
            .run_id = 1,
        }, std.testing.allocator, &request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .allow_once);
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    try std.testing.expect(std.mem.indexOf(
        u8,
        Probe.last_request[0..Probe.last_request_len],
        "\"tool_call_id\":\"call-allow\"",
    ) != null);

    // The next invocation is decided before the callback. Product-level
    // name-only SessionRules and the settings writer never participate.
    try std.testing.expectEqual(
        core.permission.PermissionResult.allow,
        AbiSession.permissionDecisionOverride(
            &fake,
            "Bash",
            "{}",
            .undecided,
        ).?,
    );
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    // Explicit ask remains stronger than a Session allow.
    try std.testing.expectEqual(
        core.permission.PermissionResult.ask,
        AbiSession.permissionDecisionOverride(
            &fake,
            "Bash",
            "{}",
            .ask,
        ).?,
    );
    const ModeCase = struct {
        mode: core.types.PermissionMode,
        explicit_ask: core.permission.PermissionResult,
    };
    for ([_]ModeCase{
        .{ .mode = .default, .explicit_ask = .ask },
        .{ .mode = .accept_edits, .explicit_ask = .ask },
        .{ .mode = .auto, .explicit_ask = .ask },
        .{ .mode = .dont_ask, .explicit_ask = .deny },
        .{ .mode = .bypass_permissions, .explicit_ask = .ask },
    }) |case| {
        native_session.permission_ctx.setMode(case.mode);
        try std.testing.expectEqual(
            case.explicit_ask,
            AbiSession.permissionDecisionOverride(
                &fake,
                "Bash",
                "{}",
                .ask,
            ).?,
        );
        try std.testing.expectEqual(
            core.permission.PermissionResult.deny,
            AbiSession.permissionDecisionOverride(
                &fake,
                "Bash",
                "{}",
                .deny,
            ).?,
        );
        try std.testing.expectEqual(
            core.permission.PermissionResult.allow,
            AbiSession.permissionDecisionOverride(
                &fake,
                "Bash",
                "{}",
                .allow,
            ).?,
        );
    }
    native_session.permission_ctx.setMode(.default);

    const mismatch_approved_args = "{\"file_path\":\"approved.txt\"}";
    const mismatch_execution_args = "{\"file_path\":\"changed.txt\"}";
    try ToolCall.append(
        native_session,
        "call-mismatch-approved",
        "Edit",
        mismatch_approved_args,
    );
    try std.testing.expect(
        AbiSession.permissionDecisionOverride(
            &fake,
            "Edit",
            mismatch_approved_args,
            .undecided,
        ) == null,
    );
    try ToolCall.append(
        native_session,
        "call-mismatch-execution",
        "Edit",
        mismatch_execution_args,
    );
    const mismatch_request = ui_request.UiRequest{ .permission = .{
        .tool = "Edit",
        .args = mismatch_execution_args,
    } };
    const calls_before_mismatch = Probe.calls;
    try std.testing.expectError(
        error.HostUiFailed,
        AbiSession.requestUi(&fake, .{
            .session_id = native_session.session_id,
            .run_id = 2,
        }, std.testing.allocator, &mismatch_request, &response),
    );
    try std.testing.expectEqual(calls_before_mismatch, Probe.calls);
    fake.callback_status.store(wire.STATUS_OK, .release);

    const write_request = ui_request.UiRequest{ .permission = .{ .tool = "Write", .args = "{}" } };
    fake.permission_audit = try session_permission.AuditTrail.init(
        std.testing.allocator,
    );
    defer if (fake.permission_audit) |*audit| audit.deinit();
    Probe.permission = "deny_session";
    Probe.calls = 0;
    Probe.releases = 0;
    try ToolCall.append(native_session, "call-deny", "Write", "{}");
    try std.testing.expect(
        AbiSession.permissionDecisionOverride(
            &fake,
            "Write",
            "{}",
            .undecided,
        ) == null,
    );
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&fake, .{
            .session_id = native_session.session_id,
            .run_id = 2,
        }, std.testing.allocator, &write_request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .deny_once);
    try std.testing.expectEqual(
        core.permission.PermissionResult.deny,
        AbiSession.permissionDecisionOverride(
            &fake,
            "Write",
            "{}",
            .allow,
        ).?,
    );
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    var last_audit = (try fake.permission_audit.?.cloneLast(
        std.testing.allocator,
    )).?;
    defer last_audit.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        session_permission.CallbackOutcome.answered,
        last_audit.callback_outcome.?,
    );
    try std.testing.expectEqual(
        session_permission.Response.deny_session,
        last_audit.response.?,
    );

    const edit_request = ui_request.UiRequest{ .permission = .{ .tool = "Edit", .args = "{}" } };
    Probe.permission = "allow_once";
    Probe.calls = 0;
    Probe.releases = 0;
    try ToolCall.append(native_session, "call-once", "Edit", "{}");
    try std.testing.expect(
        AbiSession.permissionDecisionOverride(
            &fake,
            "Edit",
            "{}",
            .undecided,
        ) == null,
    );
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&fake, .{
            .session_id = native_session.session_id,
            .run_id = 3,
        }, std.testing.allocator, &edit_request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .allow_once);
    try std.testing.expectEqual(@as(usize, 2), fake.permission_state.ruleCount());
    try std.testing.expect(
        AbiSession.permissionDecisionOverride(
            &fake,
            "Edit",
            "{}",
            .undecided,
        ) == null,
    );

    // dont_ask rejects both an explicit ask and a Core-safety prompt without
    // invoking the Host callback.
    native_session.permission_ctx.setMode(.dont_ask);
    const calls_before_dont_ask = Probe.calls;
    try ToolCall.append(native_session, "call-dont-ask-explicit", "Bash", "{}");
    try std.testing.expectEqual(
        core.permission.PermissionResult.deny,
        AbiSession.permissionDecisionOverride(
            &fake,
            "Bash",
            "{}",
            .ask,
        ).?,
    );
    fake.pending_permission = null;
    try ToolCall.append(native_session, "call-dont-ask-safety", "Edit", "{}");
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&fake, .{
            .session_id = native_session.session_id,
            .run_id = 4,
        }, std.testing.allocator, &edit_request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .deny_once);
    try std.testing.expectEqual(calls_before_dont_ask, Probe.calls);
    native_session.permission_ctx.setMode(.default);

    Probe.status = wire.UI_UNAVAILABLE;
    try ToolCall.append(native_session, "call-unavailable", "Edit", "{}");
    try std.testing.expect(
        AbiSession.permissionDecisionOverride(
            &fake,
            "Edit",
            "{}",
            .undecided,
        ) == null,
    );
    try std.testing.expectEqual(
        ui_request.RequestOutcome.unavailable,
        try AbiSession.requestUi(&fake, .{
            .session_id = native_session.session_id,
            .run_id = 5,
        }, std.testing.allocator, &edit_request, &response),
    );
    try std.testing.expectEqual(wire.STATUS_OK, fake.callback_status.load(.acquire));
    last_audit.deinit(std.testing.allocator);
    last_audit = (try fake.permission_audit.?.cloneLast(
        std.testing.allocator,
    )).?;
    try std.testing.expectEqual(
        session_permission.CallbackOutcome.unavailable,
        last_audit.callback_outcome.?,
    );
    try std.testing.expectEqualStrings(
        "call-unavailable",
        last_audit.tool_call_id,
    );

    Probe.status = wire.UI_CANCELLED;
    try ToolCall.append(native_session, "call-cancelled", "Edit", "{}");
    try std.testing.expect(
        AbiSession.permissionDecisionOverride(
            &fake,
            "Edit",
            "{}",
            .undecided,
        ) == null,
    );
    try std.testing.expectError(
        error.UiCancelled,
        AbiSession.requestUi(&fake, .{
            .session_id = native_session.session_id,
            .run_id = 6,
        }, std.testing.allocator, &edit_request, &response),
    );
    last_audit.deinit(std.testing.allocator);
    last_audit = (try fake.permission_audit.?.cloneLast(
        std.testing.allocator,
    )).?;
    try std.testing.expectEqual(
        session_permission.CallbackOutcome.user_cancelled,
        last_audit.callback_outcome.?,
    );

    // An explicit ask does not offer allow_session. Returning it anyway is a
    // callback contract failure, not an answered allow or a user denial.
    Probe.status = wire.UI_ANSWERED;
    Probe.permission = "allow_session";
    try ToolCall.append(native_session, "call-contract", "Bash", "{}");
    try std.testing.expectEqual(
        core.permission.PermissionResult.ask,
        AbiSession.permissionDecisionOverride(
            &fake,
            "Bash",
            "{}",
            .ask,
        ).?,
    );
    try std.testing.expectError(
        error.InvalidResponse,
        AbiSession.requestUi(&fake, .{
            .session_id = native_session.session_id,
            .run_id = 7,
        }, std.testing.allocator, &request, &response),
    );
    last_audit.deinit(std.testing.allocator);
    last_audit = (try fake.permission_audit.?.cloneLast(
        std.testing.allocator,
    )).?;
    try std.testing.expectEqual(
        session_permission.CallbackOutcome.contract_failure,
        last_audit.callback_outcome.?,
    );
    try std.testing.expectEqual(
        wire.STATUS_CALLBACK_FAILED,
        fake.callback_status.load(.acquire),
    );
    try native_session.updatePermissionRules(.{
        .allow = &.{"Bash(git *)"},
        .ask = &.{"Bash(*)"},
    });
    native_session.permission_ctx.session_rules = null;
    native_session.permission_ctx.decision_override = .{
        .ctx = &fake,
        .decideFn = AbiSession.permissionDecisionOverride,
    };
    try std.testing.expectEqual(
        core.permission.PermissionResult.ask,
        core.permission.checkPermission(
            &native_session.permission_ctx,
            "Bash",
            "{\"command\":\"git status\"}",
        ),
    );
    const metacodes_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root_buffer[0..root_len], ".metacodes" },
    );
    defer std.testing.allocator.free(metacodes_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, metacodes_path, .{}),
    );
    const claude_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root_buffer[0..root_len], ".claude" },
    );
    defer std.testing.allocator.free(claude_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, claude_path, .{}),
    );
}

test "Revision 6 MCP schema denial precedes Permission callback eligibility" {
    const fixture = @import("mcp_test_support.zig");
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
    var server = fixture.Server{};
    const binding = [_]u8{0x72} ** 32;
    const specs = [_]mcp_catalog.ServerSpec{.{
        .binding = binding,
        .namespace = "weather",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var runtime = AbiRuntime{
        .core_runtime = native_runtime,
        .host_tools = &.{},
        .catalogs = skill_catalog_handles.RuntimeCatalogs.initWithSecret(
            std.testing.allocator,
            [_]u8{0x73} ** 32,
        ),
        .materializations = undefined,
        .mcp_manager = try mcp_catalog.Manager.init(std.testing.allocator, &specs, .{}),
    };
    defer {
        if (runtime.mcp_manager) |*manager| manager.deinit();
        runtime.mcp_manager = null;
        runtime.catalogs.tryBeginDestroy() catch unreachable;
        runtime.catalogs.finishDestroy();
    }
    try std.testing.expectEqual(@as(u64, 1), try runtime.mcp_manager.?.refresh());
    const session = try buildAbiSession(&runtime, .{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = null,
        .permission_mode = .default,
        .permission_rules = null,
        .workspace = .{ .root = cwd, .home = cwd },
        .allowed_tools = &.{},
        .workspace_scope_id = [_]u8{0} ** 64,
        .skill_binding = null,
        .mcp_selectors = &.{.{
            .server_binding_identity = binding,
            .tool_name = "weather",
        }},
    });
    defer {
        session.active_mcp_view = null;
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        const status = sessionDestroy(session.handle(), &diagnostic);
        bufferRelease(&diagnostic);
        std.debug.assert(status == wire.STATUS_OK);
    }
    session.active_mcp_view = &session.mcp_view.?;
    const model_name = session.mcp_view.?.entries[0].model_name;
    try std.testing.expectEqual(
        core.permission.PermissionResult.deny,
        core.permission.checkPermission(
            &session.core_session.permission_ctx,
            model_name,
            "{\"city\":7}",
        ),
    );
    try std.testing.expect(session.pending_permission == null);
    try std.testing.expectEqual(
        core.permission.PermissionResult.ask,
        core.permission.checkPermission(
            &session.core_session.permission_ctx,
            model_name,
            "{\"city\":\"Paris\"}",
        ),
    );
    const pending = session.pending_permission.?;
    try std.testing.expectEqual(session_permission.ToolNamespace.mcp, pending.tool_namespace);
    try std.testing.expectEqualStrings("weather", pending.tool_name);
    try std.testing.expectEqualSlices(
        u8,
        &session.mcp_view.?.entries[0].permissionIdentity().binding,
        &pending.binding,
    );
    const ModeCase = struct {
        mode: core.types.PermissionMode,
        expected: core.permission.PermissionResult,
    };
    for ([_]ModeCase{
        .{ .mode = .accept_edits, .expected = .ask },
        .{ .mode = .auto, .expected = .ask },
        .{ .mode = .dont_ask, .expected = .deny },
        .{ .mode = .bypass_permissions, .expected = .allow },
        .{ .mode = .plan, .expected = .deny },
    }) |case| {
        session.core_session.permission_ctx.setMode(case.mode);
        try std.testing.expectEqual(
            case.expected,
            core.permission.checkPermission(
                &session.core_session.permission_ctx,
                model_name,
                "{\"city\":\"Paris\"}",
            ),
        );
    }
    session.core_session.permission_ctx.setMode(.default);
}

test "Revision 6 MCP view update is idle atomic and invalidates schema-bound grants" {
    const fixture = @import("mcp_test_support.zig");
    const Cleanup = struct {
        fn session(value: *AbiSession) void {
            var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
            const status = sessionDestroy(value.handle(), &diagnostic);
            bufferRelease(&diagnostic);
            std.debug.assert(status == wire.STATUS_OK);
        }
    };
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
    var server = fixture.Server{};
    const binding = [_]u8{0x74} ** 32;
    const specs = [_]mcp_catalog.ServerSpec{.{
        .binding = binding,
        .namespace = "weather",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var runtime = AbiRuntime{
        .core_runtime = native_runtime,
        .host_tools = &.{},
        .catalogs = skill_catalog_handles.RuntimeCatalogs.initWithSecret(
            std.testing.allocator,
            [_]u8{0x75} ** 32,
        ),
        .materializations = undefined,
        .mcp_manager = try mcp_catalog.Manager.init(std.testing.allocator, &specs, .{}),
    };
    defer {
        if (runtime.mcp_manager) |*manager| manager.deinit();
        runtime.mcp_manager = null;
        runtime.catalogs.tryBeginDestroy() catch unreachable;
        runtime.catalogs.finishDestroy();
    }
    try std.testing.expectEqual(@as(u64, 1), try runtime.mcp_manager.?.refresh());
    const selectors = [_]mcp_session.Selector{.{
        .server_binding_identity = binding,
        .tool_name = "weather",
    }};
    const session = try buildAbiSession(&runtime, .{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = null,
        .permission_mode = .default,
        .permission_rules = null,
        .workspace = .{ .root = cwd, .home = cwd },
        .allowed_tools = &.{},
        .workspace_scope_id = [_]u8{0} ** 64,
        .skill_binding = null,
        .mcp_selectors = &selectors,
    });
    defer Cleanup.session(session);
    const old_model_name = try std.testing.allocator.dupe(
        u8,
        session.mcp_view.?.entries[0].model_name,
    );
    defer std.testing.allocator.free(old_model_name);
    const old_identity = session.mcp_view.?.entries[0].permissionIdentity();
    const digest = try session_permission.digestCanonicalArguments(
        std.testing.allocator,
        "{\"city\":\"Paris\"}",
        .{},
    );
    _ = try session.permission_state.remember(
        .allow_session,
        (try session_permission.deriveRuleCandidate(old_identity, digest)).?,
        session.policy_generation,
    );
    try std.testing.expectEqual(@as(usize, 1), session.permission_state.ruleCount());

    session.call_state = .running;
    try std.testing.expectError(
        error.SessionBusy,
        session.updateMcpView(&selectors, .fresh),
    );
    session.call_state = .idle;
    try std.testing.expectEqual(@as(u64, 1), session.catalog_generation);
    try std.testing.expectEqual(@as(usize, 1), session.permission_state.ruleCount());

    server.input_schema_json =
        "{\"type\":\"object\",\"properties\":{\"country\":{\"type\":\"string\"}},\"required\":[\"country\"],\"additionalProperties\":false}";
    try std.testing.expectEqual(@as(u64, 2), try runtime.mcp_manager.?.refresh());
    try session.updateMcpView(&selectors, .fresh);
    try std.testing.expectEqual(@as(u64, 2), session.catalog_generation);
    try std.testing.expectEqualStrings(old_model_name, session.mcp_view.?.entries[0].model_name);
    try std.testing.expect(!std.mem.eql(
        u8,
        &old_identity.binding,
        &session.mcp_view.?.entries[0].permissionIdentity().binding,
    ));
    try std.testing.expectEqual(@as(usize, 0), session.permission_state.ruleCount());
    try std.testing.expectEqual(@as(u32, 1), session.invalidated_mcp_bindings);
    try std.testing.expectEqual(session_authority.RestoreHealth.degraded, session.restore_health);
    try std.testing.expect(session.mcp_view.?.validatesInvocation(
        old_model_name,
        "{\"country\":\"France\"}",
    ));
    try std.testing.expect(!session.mcp_view.?.validatesInvocation(
        old_model_name,
        "{\"city\":\"Paris\"}",
    ));
}

test "Revision 6 checkpoint restores compatible MCP view and exact Session grant" {
    const fixture = @import("mcp_test_support.zig");
    const Cleanup = struct {
        fn session(value: *AbiSession) void {
            var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
            const status = sessionDestroy(value.handle(), &diagnostic);
            bufferRelease(&diagnostic);
            std.debug.assert(status == wire.STATUS_OK);
        }
    };
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
    var server = fixture.Server{};
    const binding = [_]u8{0x76} ** 32;
    const specs = [_]mcp_catalog.ServerSpec{.{
        .binding = binding,
        .namespace = "weather",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var runtime = AbiRuntime{
        .core_runtime = native_runtime,
        .host_tools = &.{},
        .catalogs = skill_catalog_handles.RuntimeCatalogs.initWithSecret(
            std.testing.allocator,
            [_]u8{0x77} ** 32,
        ),
        .materializations = undefined,
        .mcp_manager = try mcp_catalog.Manager.init(std.testing.allocator, &specs, .{}),
    };
    defer {
        if (runtime.mcp_manager) |*manager| manager.deinit();
        runtime.mcp_manager = null;
        runtime.catalogs.tryBeginDestroy() catch unreachable;
        runtime.catalogs.finishDestroy();
    }
    try std.testing.expectEqual(@as(u64, 1), try runtime.mcp_manager.?.refresh());
    var workspace = try skill_catalog_handles.CanonicalWorkspace.init(
        std.testing.allocator,
        cwd,
        cwd,
    );
    defer workspace.deinit();
    const scope_id = try runtime.catalogs.scopeId(&workspace);
    const selectors = [_]mcp_session.Selector{.{
        .server_binding_identity = binding,
        .tool_name = "weather",
    }};
    const original = try buildAbiSession(&runtime, .{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .provider_kind = .anthropic,
        .api_key = "old-key",
        .model = "checkpoint-model",
        .base_url = null,
        .permission_mode = .default,
        .permission_rules = null,
        .workspace = .{ .root = cwd, .home = cwd },
        .allowed_tools = &.{},
        .workspace_scope_id = scope_id,
        .skill_binding = null,
        .mcp_selectors = &selectors,
    });
    var original_live = true;
    defer if (original_live) Cleanup.session(original);
    try original.core_session.conversation.appendText(.user, "restore MCP authority safely");
    const arguments_json = "{\"city\":\"Paris\"}";
    const digest = try session_permission.digestCanonicalArguments(
        std.testing.allocator,
        arguments_json,
        .{},
    );
    const original_entry = &original.mcp_view.?.entries[0];
    _ = try original.permission_state.remember(
        .allow_session,
        (try session_permission.deriveRuleCandidate(
            original_entry.permissionIdentity(),
            digest,
        )).?,
        original.policy_generation,
    );
    const expected_model_name = try std.testing.allocator.dupe(u8, original_entry.model_name);
    defer std.testing.allocator.free(expected_model_name);
    var checkpoint = TestCheckpointBuffer{ .allocator = std.testing.allocator };
    defer checkpoint.deinit();
    const limits = session_checkpoint.Limits{
        .hard_bytes = 1024 * 1024,
        .chunk_bytes = 37,
    };
    _ = try original.exportCheckpoint(limits, checkpoint.sink());
    var decoded = try session_checkpoint.decodeFromSource(
        std.testing.allocator,
        checkpoint.source(),
        limits,
    );
    defer decoded.deinit();
    try std.testing.expect(decoded.mcp_state.len != 0);
    var decoded_mcp = (try mcp_checkpoint.decode(
        std.testing.allocator,
        decoded.mcp_state,
    )).?;
    defer decoded_mcp.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded_mcp.entries.len);
    try std.testing.expectEqualStrings("weather", decoded_mcp.entries[0].tool_name);
    Cleanup.session(original);
    original_live = false;

    const restore_config = RestoreHostConfig{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .provider_kind = .anthropic,
        .api_key = "current-key",
        .base_url = null,
        .permission_mode = .default,
        .permission_rules = null,
        .workspace = .{ .root = cwd, .home = cwd },
        .allowed_tools = &.{},
        .workspace_scope_id = scope_id,
    };
    var no_binding: ?SkillBinding = null;
    const restored = try restoreCheckpoint(
        &runtime,
        restore_config,
        &no_binding,
        checkpoint.source(),
        limits,
    );
    var restored_live = true;
    defer if (restored_live) Cleanup.session(restored.session);
    try std.testing.expectEqual(session_authority.RestoreHealth.complete, restored.report.health);
    try std.testing.expectEqual(@as(u32, 1), restored.report.mcp_bindings_restored);
    try std.testing.expectEqual(@as(u32, 0), restored.report.mcp_bindings_invalidated);
    try std.testing.expectEqual(@as(u32, 1), restored.report.permission_rules_restored);
    try std.testing.expectEqual(@as(u32, 0), restored.report.permission_rules_invalidated);
    try std.testing.expectEqual(@as(u64, 1), restored.report.catalog_generation);
    try std.testing.expectEqualStrings(
        expected_model_name,
        restored.session.mcp_view.?.entries[0].model_name,
    );
    try std.testing.expectEqual(
        session_permission.Decision.allow,
        (try restored.session.permission_state.decide(
            restored.session.mcp_view.?.entries[0].permissionIdentity(),
            digest,
            .undecided,
            .{ .decision = .ask, .source = .mode_fallback },
        )).decision,
    );
    try std.testing.expectEqual(@as(usize, 1), restored.session.core_session.conversation.len());
    try std.testing.expectEqualStrings("current-key", restored.session.core_session.api_key);

    Cleanup.session(restored.session);
    restored_live = false;
    server.input_schema_json =
        "{\"type\":\"object\",\"properties\":{\"country\":{\"type\":\"string\"}},\"required\":[\"country\"],\"additionalProperties\":false}";
    try std.testing.expectEqual(@as(u64, 2), try runtime.mcp_manager.?.refresh());
    const changed = try restoreCheckpoint(
        &runtime,
        restore_config,
        &no_binding,
        checkpoint.source(),
        limits,
    );
    defer Cleanup.session(changed.session);
    try std.testing.expectEqual(session_authority.RestoreHealth.degraded, changed.report.health);
    try std.testing.expectEqual(@as(u32, 0), changed.report.mcp_bindings_restored);
    try std.testing.expectEqual(@as(u32, 1), changed.report.mcp_bindings_invalidated);
    try std.testing.expectEqual(@as(u32, 0), changed.report.permission_rules_restored);
    try std.testing.expectEqual(@as(u32, 1), changed.report.permission_rules_invalidated);
    try std.testing.expectEqual(@as(u64, 2), changed.report.catalog_generation);
    try std.testing.expectEqual(@as(usize, 0), changed.session.mcp_view.?.entries.len);
    try std.testing.expectEqual(@as(usize, 1), changed.session.core_session.conversation.len());
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

test "Revision 6 AgentCore checkpoint export commits generation only after sink success" {
    const CaptureSink = struct {
        allocator: std.mem.Allocator,
        bytes: std.ArrayList(u8) = .empty,
        fail: bool = false,
        read_offset: usize = 0,

        fn write(raw: *anyopaque, part: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.fail) return error.HostSinkFailed;
            try self.bytes.appendSlice(self.allocator, part);
        }

        fn sink(self: *@This()) session_checkpoint.Sink {
            return .{ .ctx = self, .write_fn = write };
        }

        fn read(raw: *anyopaque, out: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.read_offset == self.bytes.items.len) return 0;
            const count = @min(
                out.len,
                self.bytes.items.len - self.read_offset,
            );
            @memcpy(
                out[0..count],
                self.bytes.items[self.read_offset..][0..count],
            );
            self.read_offset += count;
            return count;
        }

        fn clear(self: *@This()) void {
            self.bytes.clearRetainingCapacity();
            self.read_offset = 0;
        }

        fn deinit(self: *@This()) void {
            self.bytes.deinit(self.allocator);
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const cwd = root_buffer[0..root_len];
    const native_runtime = try core.agent_session.AgentRuntime.create(
        std.testing.allocator,
        .{ .builtin_tools = &.{"Read"} },
    );
    const native_session = try native_runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"Read"},
    });
    try native_session.conversation.appendText(.user, "persist me");
    var runtime = AbiRuntime{
        .core_runtime = native_runtime,
        .host_tools = &.{},
        .catalogs = skill_catalog_handles.RuntimeCatalogs.initWithSecret(
            std.testing.allocator,
            [_]u8{0x61} ** 32,
        ),
        .materializations = undefined,
    };
    var session = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = native_session,
        .runtime = &runtime,
    };
    defer session.permission_state.deinit();
    session.policy_fingerprint = try session_permission.computePolicyFingerprint(
        std.testing.allocator,
        .default,
        null,
        .{ .root = cwd, .home = cwd },
        &.{"Read"},
    );
    const read_digest = try session_permission.digestCanonicalArguments(
        std.testing.allocator,
        "{\"file_path\":\"README.md\"}",
        .{},
    );
    _ = try session.permission_state.remember(
        .allow_session,
        (try session_permission.deriveRuleCandidate(.{
            .namespace = .builtin,
            .name = "Read",
        }, read_digest)).?,
        1,
    );
    var capture = CaptureSink{ .allocator = std.testing.allocator };
    defer capture.deinit();
    const limits = session_checkpoint.Limits{
        .hard_bytes = 1024 * 1024,
        .chunk_bytes = 17,
    };

    const first = try session.exportCheckpoint(limits, capture.sink());
    try std.testing.expectEqual(@as(u64, 1), session.checkpoint_generation);
    try std.testing.expectEqual(first.total_bytes, capture.bytes.items.len);
    try std.testing.expect(std.mem.indexOf(u8, capture.bytes.items, "test-key") == null);
    try std.testing.expectEqual(AbiSession.CallState.idle, session.call_state);
    var description = try session.describe(std.testing.allocator);
    defer description.deinit();
    try std.testing.expectEqual(@as(u64, 1), description.checkpoint_generation);
    try std.testing.expectEqualStrings("test-model", description.model);
    try std.testing.expectEqual(@as(u64, 1), description.conversation_messages);
    try std.testing.expectEqualSlices(
        u8,
        native_session.session_id.asSlice(),
        description.session_id.asSlice(),
    );

    capture.clear();
    capture.fail = true;
    try std.testing.expectError(
        error.SinkFailed,
        session.exportCheckpoint(limits, capture.sink()),
    );
    try std.testing.expectEqual(@as(u64, 1), session.checkpoint_generation);
    try std.testing.expectEqual(AbiSession.CallState.idle, session.call_state);
    var lease = try native_session.snapshotCommitted();
    lease.deinit();

    capture.fail = false;
    const second = try session.exportCheckpoint(limits, capture.sink());
    try std.testing.expectEqual(@as(u64, 2), session.checkpoint_generation);
    try std.testing.expectEqual(second.total_bytes, capture.bytes.items.len);
    const source = session_checkpoint.Source{
        .ctx = &capture,
        .read_fn = CaptureSink.read,
    };
    var decoded = try session_checkpoint.decodeFromSource(
        std.testing.allocator,
        source,
        limits,
    );
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 2), decoded.descriptor.checkpoint_generation);
    try std.testing.expectEqualStrings("test-model", decoded.model);
    try std.testing.expectEqual(@as(usize, 0), decoded.skill_state.len);
    var decoded_permission = try session_authority.decodePermissionState(
        std.testing.allocator,
        decoded.permission_state,
    );
    defer decoded_permission.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded_permission.rules.len);

    var event_ctx: u8 = 0;
    var active_run = try native_session.admitRun(1, TestEventSink.sink(&event_ctx));
    capture.clear();
    try std.testing.expectError(
        error.SessionBusy,
        session.exportCheckpoint(limits, capture.sink()),
    );
    try std.testing.expectEqual(@as(u64, 2), session.checkpoint_generation);
    try std.testing.expectEqual(AbiSession.CallState.idle, session.call_state);
    try std.testing.expectEqual(@as(usize, 0), capture.bytes.items.len);
    _ = try active_run.finishWithoutConversation();
    var after_busy = try session.describe(std.testing.allocator);
    after_busy.deinit();

    session.call_state = .running;
    try std.testing.expectError(
        error.SessionBusy,
        session.exportCheckpoint(limits, capture.sink()),
    );
    try std.testing.expectError(
        error.SessionBusy,
        session.describe(std.testing.allocator),
    );
    session.call_state = .idle;
    capture.clear();
    _ = try session.exportCheckpoint(limits, capture.sink());
    try std.testing.expectEqual(@as(u64, 3), session.checkpoint_generation);

    try native_session.destroy();
    try native_runtime.destroy();
    try runtime.catalogs.tryBeginDestroy();
    runtime.catalogs.finishDestroy();
}

test "Revision 6 AgentCore restore is atomic and continues logical operation IDs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const cwd = root_buffer[0..root_len];
    const native_runtime = try core.agent_session.AgentRuntime.create(
        std.testing.allocator,
        .{ .builtin_tools = &.{"Read"} },
    );
    const original = try native_runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "old-key",
        .model = "checkpoint-model",
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{"Read"},
    });
    try original.conversation.appendText(.user, "survives restore");
    var event_ctx: u8 = 0;
    var admitted = try original.admitRun(7, TestEventSink.sink(&event_ctx));
    _ = try admitted.finishWithoutConversation();

    var runtime = AbiRuntime{
        .core_runtime = native_runtime,
        .host_tools = &.{},
        .catalogs = skill_catalog_handles.RuntimeCatalogs.initWithSecret(
            std.testing.allocator,
            [_]u8{0x62} ** 32,
        ),
        .materializations = undefined,
    };
    var original_facade = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = original,
        .runtime = &runtime,
        .permission_state = try session_permission.State.init(std.testing.allocator, 1),
    };
    defer original_facade.permission_state.deinit();
    original_facade.policy_fingerprint = try session_permission.computePolicyFingerprint(
        std.testing.allocator,
        .default,
        null,
        .{ .root = cwd, .home = cwd },
        &.{"Read"},
    );
    const read_digest = try session_permission.digestCanonicalArguments(
        std.testing.allocator,
        "{\"file_path\":\"README.md\"}",
        .{},
    );
    const read_candidate = (try session_permission.deriveRuleCandidate(.{
        .namespace = .builtin,
        .name = "Read",
    }, read_digest)).?;
    _ = try original_facade.permission_state.remember(
        .allow_session,
        read_candidate,
        1,
    );
    original_facade.recordTerminal(.run, 7);
    var checkpoint = TestCheckpointBuffer{ .allocator = std.testing.allocator };
    defer checkpoint.deinit();
    const limits = session_checkpoint.Limits{
        .hard_bytes = 1024 * 1024,
        .chunk_bytes = 23,
    };
    _ = try original_facade.exportCheckpoint(limits, checkpoint.sink());
    try std.testing.expect(std.mem.indexOf(u8, checkpoint.bytes.items, "old-key") == null);

    var canonical_workspace = try skill_catalog_handles.CanonicalWorkspace.init(
        std.testing.allocator,
        cwd,
        cwd,
    );
    defer canonical_workspace.deinit();
    const scope_id = try runtime.catalogs.scopeId(&canonical_workspace);
    const restore_config = RestoreHostConfig{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .provider_kind = .anthropic,
        .api_key = "new-key",
        .base_url = null,
        .permission_mode = .default,
        .permission_rules = null,
        .workspace = .{ .root = cwd, .home = cwd },
        .allowed_tools = &.{"Read"},
        .workspace_scope_id = scope_id,
    };
    var no_binding: ?SkillBinding = null;

    try std.testing.expectError(
        error.SessionAlreadyOpen,
        restoreCheckpoint(
            &runtime,
            restore_config,
            &no_binding,
            checkpoint.source(),
            limits,
        ),
    );
    try std.testing.expect(no_binding == null);

    const first_byte = checkpoint.bytes.items[0];
    checkpoint.bytes.items[0] = 'X';
    try std.testing.expectError(
        error.Corrupt,
        restoreCheckpoint(
            &runtime,
            restore_config,
            &no_binding,
            checkpoint.source(),
            limits,
        ),
    );
    checkpoint.bytes.items[0] = first_byte;

    try original.destroy();
    const restored = try restoreCheckpoint(
        &runtime,
        restore_config,
        &no_binding,
        checkpoint.source(),
        limits,
    );
    try std.testing.expectEqual(
        session_authority.RestoreHealth.complete,
        restored.report.health,
    );
    try std.testing.expectEqual(@as(u32, 1), restored.report.permission_rules_restored);
    try std.testing.expectEqual(@as(u32, 0), restored.report.permission_rules_invalidated);
    try std.testing.expectEqual(@as(usize, 1), restored.session.permission_state.ruleCount());
    try std.testing.expectEqual(
        session_permission.Decision.allow,
        (try restored.session.permission_state.decide(
            .{ .namespace = .builtin, .name = "Read" },
            read_digest,
            .undecided,
            .{ .decision = .ask, .source = .mode_fallback },
        )).decision,
    );
    try std.testing.expectEqual(@as(u64, 1), restored.report.checkpoint_generation);
    try std.testing.expectEqual(
        session_authority.LogicalOrigin.restored,
        restored.session.logical_origin,
    );
    try std.testing.expectEqual(@as(usize, 1), restored.session.core_session.conversation.len());
    try std.testing.expectEqualStrings("checkpoint-model", restored.session.core_session.model);
    try std.testing.expectEqualStrings("new-key", restored.session.core_session.api_key);
    try std.testing.expectError(
        error.StaleRun,
        restored.session.core_session.admitRun(7, TestEventSink.sink(&event_ctx)),
    );
    var continued = try restored.session.core_session.admitRun(
        8,
        TestEventSink.sink(&event_ctx),
    );
    _ = try continued.finishWithoutConversation();

    var description = try restored.session.describe(std.testing.allocator);
    defer description.deinit();
    try std.testing.expectEqual(@as(u64, 8), description.last_run_id);
    try std.testing.expectEqual(@as(u64, 1), description.checkpoint_generation);
    try std.testing.expectEqual(session_authority.LogicalOrigin.restored, description.origin);

    var continued_checkpoint = TestCheckpointBuffer{ .allocator = std.testing.allocator };
    defer continued_checkpoint.deinit();
    _ = try restored.session.exportCheckpoint(limits, continued_checkpoint.sink());
    var decoded = try session_checkpoint.decodeFromSource(
        std.testing.allocator,
        continued_checkpoint.source(),
        limits,
    );
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 2), decoded.descriptor.checkpoint_generation);
    try std.testing.expectEqual(@as(u64, 8), decoded.descriptor.last_run_id);
    try std.testing.expectEqual(session_checkpoint.TerminalKind.run, decoded.descriptor.terminal_kind);
    try std.testing.expectEqual(@as(u64, 8), decoded.descriptor.terminal_id);

    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer bufferRelease(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        sessionDestroy(restored.session.handle(), &diagnostic),
    );
    try native_runtime.destroy();
    try runtime.catalogs.tryBeginDestroy();
    runtime.catalogs.finishDestroy();
}

test "Revision 6 AgentCore restore degrades unavailable and changed Skill authority" {
    const record = skill_catalog.SkillRecord{
        .skill_id = [_]u8{'1'} ** 64,
        .invocation_name = "checkpoint-skill",
        .definition = .{
            .name = "checkpoint-skill",
            .description = "checkpoint-skill",
            .body = "checkpoint-skill",
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
        .scope_id = [_]u8{'2'} ** 64,
        .revision = [_]u8{'3'} ** 64,
        .health = .healthy,
        .skills = &.{record},
        .issues = &.{},
        .descriptor_json = "",
        .snapshot_bytes = 0,
        .resident_bytes = 0,
    };
    var selection = try skill_availability.Selection.init(
        std.testing.allocator,
        &snapshot,
        .{ .default_state = .enabled, .exceptions = &.{} },
    );
    defer selection.deinit();
    const skill_state = try session_authority.encodeSkillState(
        std.testing.allocator,
        &snapshot,
        &selection,
    );
    defer std.testing.allocator.free(skill_state);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const cwd = root_buffer[0..root_len];
    var permission_owner = try session_permission.State.init(
        std.testing.allocator,
        1,
    );
    defer permission_owner.deinit();
    const policy_fingerprint = try session_permission.computePolicyFingerprint(
        std.testing.allocator,
        .default,
        null,
        .{ .root = cwd, .home = cwd },
        &.{},
    );
    const permission_state = try session_authority.encodePermissionState(
        std.testing.allocator,
        .default,
        &permission_owner,
        policy_fingerprint,
    );
    defer std.testing.allocator.free(permission_state);
    var conversation = core.conversation.Conversation.init(std.testing.allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "restore even when Skill is unavailable");
    const logical_id = core.session_id.SessionId.fromSlice(
        "0000000000000000000000bb",
    ).?;
    const limits = session_checkpoint.Limits{
        .hard_bytes = 1024 * 1024,
        .chunk_bytes = 31,
    };
    var checkpoint = TestCheckpointBuffer{ .allocator = std.testing.allocator };
    defer checkpoint.deinit();
    _ = try session_checkpoint.exportToSink(.{
        .session_id = logical_id,
        .checkpoint_generation = 1,
        .last_run_id = 0,
        .last_compact_id = 0,
        .terminal_kind = .none,
        .terminal_id = 0,
        .model = "checkpoint-model",
        .conversation = &conversation,
        .policy_generation = 1,
        .authority = .{
            .skill = skill_state,
            .permission = permission_state,
        },
    }, limits, checkpoint.sink());

    const native_runtime = try core.agent_session.AgentRuntime.create(
        std.testing.allocator,
        .{ .builtin_tools = &.{} },
    );
    var runtime = AbiRuntime{
        .core_runtime = native_runtime,
        .host_tools = &.{},
        .catalogs = skill_catalog_handles.RuntimeCatalogs.initWithSecret(
            std.testing.allocator,
            [_]u8{0x63} ** 32,
        ),
        .materializations = undefined,
    };
    var workspace = try skill_catalog_handles.CanonicalWorkspace.init(
        std.testing.allocator,
        cwd,
        cwd,
    );
    defer workspace.deinit();
    const scope_id = try runtime.catalogs.scopeId(&workspace);
    const base_config = RestoreHostConfig{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .provider_kind = .anthropic,
        .api_key = "new-key",
        .base_url = null,
        .permission_mode = .default,
        .permission_rules = null,
        .workspace = .{ .root = cwd, .home = cwd },
        .allowed_tools = &.{},
        .workspace_scope_id = scope_id,
    };

    var no_binding: ?SkillBinding = null;
    var mismatched_mode = base_config;
    mismatched_mode.permission_mode = .auto;
    const narrowed_permission = try restoreCheckpoint(
        &runtime,
        mismatched_mode,
        &no_binding,
        checkpoint.source(),
        limits,
    );
    try std.testing.expectEqual(
        session_authority.RestoreHealth.degraded,
        narrowed_permission.report.health,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        narrowed_permission.report.policy_generation,
    );
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        sessionDestroy(narrowed_permission.session.handle(), &diagnostic),
    );
    bufferRelease(&diagnostic);

    const unavailable = try restoreCheckpoint(
        &runtime,
        base_config,
        &no_binding,
        checkpoint.source(),
        limits,
    );
    try std.testing.expectEqual(
        session_authority.RestoreHealth.degraded,
        unavailable.report.health,
    );
    try std.testing.expectEqual(
        session_authority.SkillDisposition.unavailable,
        unavailable.report.skill.disposition,
    );
    try std.testing.expectEqual(@as(u32, 1), unavailable.report.skill.invalidated);
    try std.testing.expect(unavailable.session.skill_binding == null);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        sessionDestroy(unavailable.session.handle(), &diagnostic),
    );
    bufferRelease(&diagnostic);

    const changed_host = try runtime.catalogs.query(
        std.testing.io,
        &workspace,
        "changed-epoch",
        &.{},
        .{},
    );
    const all_enabled = skill_availability.Spec{
        .default_state = .enabled,
        .exceptions = &.{},
    };
    var changed_binding = try createInitialSkillBinding(
        &runtime,
        &scope_id,
        changed_host,
        &all_enabled,
    );
    try changed_host.release();
    const changed = try restoreCheckpoint(
        &runtime,
        base_config,
        &changed_binding,
        checkpoint.source(),
        limits,
    );
    try std.testing.expect(changed_binding == null);
    try std.testing.expectEqual(
        session_authority.RestoreHealth.degraded,
        changed.report.health,
    );
    try std.testing.expectEqual(
        session_authority.SkillDisposition.changed,
        changed.report.skill.disposition,
    );
    try std.testing.expectEqual(@as(u32, 1), changed.report.skill.invalidated);
    try std.testing.expect(changed.session.skill_binding == null);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        sessionDestroy(changed.session.handle(), &diagnostic),
    );
    bufferRelease(&diagnostic);

    try native_runtime.destroy();
    try runtime.catalogs.tryBeginDestroy();
    runtime.catalogs.finishDestroy();
}

test "Revision 6 restore preserves Conversation and invalidates unavailable MCP authority" {
    const Cleanup = struct {
        fn session(value: *AbiSession) void {
            var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
            const status = sessionDestroy(value.handle(), &diagnostic);
            bufferRelease(&diagnostic);
            std.debug.assert(status == wire.STATUS_OK);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const cwd = root_buffer[0..root_len];
    var permission_owner = try session_permission.State.init(std.testing.allocator, 3);
    defer permission_owner.deinit();
    const policy_fingerprint = try session_permission.computePolicyFingerprint(
        std.testing.allocator,
        .default,
        null,
        .{ .root = cwd, .home = cwd },
        &.{},
    );
    const arguments_digest = try session_permission.digestCanonicalArguments(
        std.testing.allocator,
        "{\"city\":\"Paris\"}",
        .{},
    );
    const permission_binding = [_]u8{0x81} ** 32;
    const candidate = (try session_permission.deriveRuleCandidate(.{
        .namespace = .mcp,
        .name = "weather",
        .binding = permission_binding,
    }, arguments_digest)).?;
    _ = try permission_owner.remember(.allow_session, candidate, 3);
    const permission_state = try session_authority.encodePermissionState(
        std.testing.allocator,
        .default,
        &permission_owner,
        policy_fingerprint,
    );
    defer std.testing.allocator.free(permission_state);
    const persisted_entries = [_]mcp_checkpoint.PersistedEntry{.{
        .server_binding_identity = [_]u8{0x82} ** 32,
        .schema_fingerprint = [_]u8{0x83} ** 32,
        .tool_name = "weather",
        .era = .modern_2026_07_28,
    }};
    const mcp_state = try mcp_checkpoint.encode(std.testing.allocator, .{
        .catalog_generation = 9,
        .catalog_fingerprint = [_]u8{0x84} ** 32,
        .selection_fingerprint = mcp_checkpoint.computeSelectionFingerprint(&persisted_entries),
        .entries = &persisted_entries,
    });
    defer std.testing.allocator.free(mcp_state);
    var conversation = core.conversation.Conversation.init(std.testing.allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "survives unavailable MCP server");
    const logical_id = core.session_id.SessionId.fromSlice(
        "0000000000000000000000cc",
    ).?;
    const limits = session_checkpoint.Limits{
        .hard_bytes = 1024 * 1024,
        .chunk_bytes = 29,
    };
    var checkpoint = TestCheckpointBuffer{ .allocator = std.testing.allocator };
    defer checkpoint.deinit();
    _ = try session_checkpoint.exportToSink(.{
        .session_id = logical_id,
        .checkpoint_generation = 4,
        .last_run_id = 0,
        .last_compact_id = 0,
        .terminal_kind = .none,
        .terminal_id = 0,
        .model = "checkpoint-model",
        .conversation = &conversation,
        .policy_generation = 3,
        .catalog_generation = 9,
        .authority = .{
            .permission = permission_state,
            .mcp = mcp_state,
        },
    }, limits, checkpoint.sink());

    const native_runtime = try core.agent_session.AgentRuntime.create(
        std.testing.allocator,
        .{ .builtin_tools = &.{} },
    );
    defer native_runtime.destroy() catch unreachable;
    var runtime = AbiRuntime{
        .core_runtime = native_runtime,
        .host_tools = &.{},
        .catalogs = skill_catalog_handles.RuntimeCatalogs.initWithSecret(
            std.testing.allocator,
            [_]u8{0x85} ** 32,
        ),
        .materializations = undefined,
    };
    defer {
        runtime.catalogs.tryBeginDestroy() catch unreachable;
        runtime.catalogs.finishDestroy();
    }
    var workspace = try skill_catalog_handles.CanonicalWorkspace.init(
        std.testing.allocator,
        cwd,
        cwd,
    );
    defer workspace.deinit();
    const scope_id = try runtime.catalogs.scopeId(&workspace);
    const restore_config = RestoreHostConfig{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .provider_kind = .anthropic,
        .api_key = "current-key",
        .base_url = null,
        .permission_mode = .default,
        .permission_rules = null,
        .workspace = .{ .root = cwd, .home = cwd },
        .allowed_tools = &.{},
        .workspace_scope_id = scope_id,
    };
    var no_binding: ?SkillBinding = null;
    const first = try restoreCheckpoint(
        &runtime,
        restore_config,
        &no_binding,
        checkpoint.source(),
        limits,
    );
    var first_live = true;
    defer if (first_live) Cleanup.session(first.session);
    try std.testing.expectEqual(session_authority.RestoreHealth.degraded, first.report.health);
    try std.testing.expectEqual(@as(u32, 0), first.report.mcp_bindings_restored);
    try std.testing.expectEqual(@as(u32, 1), first.report.mcp_bindings_invalidated);
    try std.testing.expectEqual(@as(u32, 0), first.report.permission_rules_restored);
    try std.testing.expectEqual(@as(u32, 1), first.report.permission_rules_invalidated);
    try std.testing.expectEqual(@as(usize, 0), first.session.permission_state.ruleCount());
    try std.testing.expect(first.session.mcp_view == null);
    try std.testing.expectEqual(@as(u64, 0), first.report.catalog_generation);
    try std.testing.expectEqual(@as(usize, 1), first.session.core_session.conversation.len());
    try std.testing.expectEqualStrings(
        "survives unavailable MCP server",
        first.session.core_session.conversation.messages.items[0].blocks[0].text,
    );

    // Once the stale authority is invalidated, the degraded Session remains
    // durably exportable: no old Runtime generation is paired with an empty
    // MCP section, and the resulting checkpoint restores again.
    var reexport = TestCheckpointBuffer{ .allocator = std.testing.allocator };
    defer reexport.deinit();
    _ = try first.session.exportCheckpoint(limits, reexport.sink());
    var decoded = try session_checkpoint.decodeFromSource(
        std.testing.allocator,
        reexport.source(),
        limits,
    );
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 0), decoded.descriptor.catalog_generation);
    try std.testing.expectEqual(@as(usize, 0), decoded.mcp_state.len);
    Cleanup.session(first.session);
    first_live = false;

    const second = try restoreCheckpoint(
        &runtime,
        restore_config,
        &no_binding,
        reexport.source(),
        limits,
    );
    defer Cleanup.session(second.session);
    try std.testing.expectEqual(@as(usize, 1), second.session.core_session.conversation.len());
    try std.testing.expectEqual(@as(u32, 0), second.report.mcp_bindings_invalidated);
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

test "Revision 6 AgentCore permission rule mutation is atomic and invalidates Session grants" {
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
        .permission_state = try session_permission.State.init(std.testing.allocator, 1),
    };
    defer session.permission_state.deinit();
    session.policy_fingerprint = try session_permission.computePolicyFingerprint(
        std.testing.allocator,
        .default,
        null,
        .{
            .root = native_session.workspace.root,
            .home = native_session.workspace.home,
            .shell = native_session.workspace.shell,
        },
        &.{},
    );
    const arguments_digest = try session_permission.digestCanonicalArguments(
        std.testing.allocator,
        "{\"command\":\"echo ok\"}",
        .{},
    );
    const candidate = (try session_permission.deriveRuleCandidate(.{
        .namespace = .builtin,
        .name = "Bash",
    }, arguments_digest)).?;
    _ = try session.permission_state.remember(.allow_session, candidate, 1);
    const initial_fingerprint = session.policy_fingerprint;

    try session.updatePermissionRules(.{
        .allow = &.{"Write"},
        .deny = &.{"Bash"},
    });
    try std.testing.expectEqual(@as(u64, 2), session.policy_generation);
    try std.testing.expectEqual(@as(u64, 2), session.permission_state.generation());
    try std.testing.expectEqual(@as(usize, 0), session.permission_state.ruleCount());
    try std.testing.expect(!std.mem.eql(
        u8,
        &initial_fingerprint,
        &session.policy_fingerprint,
    ));
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
    _ = try session.permission_state.remember(.deny_session, candidate, 2);
    const published_generation = session.policy_generation;
    const published_fingerprint = session.policy_fingerprint;

    try std.testing.expectError(
        error.InvalidRule,
        session.updatePermissionRules(.{ .allow = &.{"Bash("} }),
    );
    try std.testing.expect(native_session.permission_ctx.settings == published);
    try std.testing.expectEqual(published_generation, session.policy_generation);
    try std.testing.expectEqual(published_generation, session.permission_state.generation());
    try std.testing.expectEqual(@as(usize, 1), session.permission_state.ruleCount());
    try std.testing.expect(std.mem.eql(
        u8,
        &published_fingerprint,
        &session.policy_fingerprint,
    ));
    try std.testing.expectEqual(
        session_permission.Decision.deny,
        (try session.permission_state.decide(
            .{ .namespace = .builtin, .name = "Bash" },
            arguments_digest,
            .undecided,
            .{ .decision = .ask, .source = .mode_fallback },
        )).decision,
    );
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
