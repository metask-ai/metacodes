//! Thin C ABI v1 facade over AgentRuntime and AgentSession.

const std = @import("std");
pub const session_checkpoint = @import("session_checkpoint.zig");
pub const session_budget = @import("session_budget.zig");
pub const session_authority = @import("session_authority.zig");
pub const session_permission = @import("session_permission.zig");
pub const mcp_protocol = @import("mcp_protocol.zig");
pub const mcp_catalog = @import("mcp_catalog.zig");
pub const mcp_runtime = @import("mcp_runtime.zig");
pub const mcp_instance_pool = @import("mcp_instance_pool.zig");
pub const mcp_negotiation = @import("mcp_negotiation.zig");
pub const mcp_session = @import("mcp_session.zig");
pub const mcp_checkpoint = @import("mcp_checkpoint.zig");
pub const mcp_canonical = @import("mcp_canonical.zig");
const builtin = @import("builtin");
const sync = @import("platform").sync;
const process = @import("platform").process;
const wire = @import("metask_agentcore_types");
const public_protocol = @import("metask_agentcore_protocol");
const run_state = @import("run_state.zig");

pub const RunStateProjector = run_state.Projector;
const core = @import("metacodes-core");
const ui_request = core.protocol.ui_request;
pub const protocol_v1 = @import("protocol_v1.zig");
const skill_runtime = core.skills_runtime;
pub const skill_catalog = skill_runtime.catalog;
pub const skill_availability = skill_runtime.availability;
pub const skill_catalog_handles = @import("skill_catalog_handles.zig");
pub const completion_handles = @import("completion_handles.zig");
pub const skill_activation = skill_runtime.activation;
pub const skill_materialization = skill_runtime.materialization;
pub const policy_frame = skill_runtime.policy_frame;
pub const event_projection = @import("event_projection.zig");
pub const model_skill_tool = @import("model_skill_tool.zig");
pub const child_permission = @import("child_permission.zig");
const model_binding = @import("model_binding.zig");
const sandbox_admission = @import("sandbox_admission.zig");

const allocator = std.heap.c_allocator;
const test_long_running_command = if (builtin.os.tag == .windows)
    "ping -n 30 127.0.0.1"
else
    "sleep 30";

comptime {
    if (wire.MAX_TOOL_ERROR_PAYLOAD_BYTES_V1 != @as(u64, core.tool_exec.MAX_TOOL_ERROR_PAYLOAD_BYTES_V1))
        @compileError("AgentCore wire and core encoded Host-error limits must match");
    const catalog_limits = skill_catalog.Limits{};
    if (catalog_limits.max_slots != @as(usize, @intCast(wire.MAX_SKILL_CATALOG_SKILLS_V1)) or
        catalog_limits.max_descriptor_bytes != @as(usize, @intCast(wire.MAX_SKILL_CATALOG_DESCRIPTOR_BYTES_V1)) or
        catalog_limits.max_file_content_bytes != @as(usize, @intCast(wire.MAX_SKILL_FILE_CONTENT_BYTES_V1)) or
        catalog_limits.max_skill_content_bytes != @as(usize, @intCast(wire.MAX_SKILL_CONTENT_BYTES_V1)) or
        catalog_limits.max_skill_files != @as(usize, @intCast(wire.MAX_SKILL_FILES_V1)) or
        catalog_limits.max_skill_entries != @as(usize, @intCast(wire.MAX_SKILL_ENTRIES_V1)) or
        catalog_limits.max_depth != @as(usize, @intCast(wire.MAX_SKILL_DIRECTORY_DEPTH_V1)) or
        catalog_limits.max_relative_path_bytes != @as(usize, @intCast(wire.MAX_SKILL_RELATIVE_PATH_BYTES_V1)) or
        catalog_limits.max_catalog_content_bytes != @as(usize, @intCast(wire.MAX_SKILL_CATALOG_CONTENT_BYTES_V1)) or
        catalog_limits.max_catalog_files != @as(usize, @intCast(wire.MAX_SKILL_CATALOG_FILES_V1)) or
        catalog_limits.max_visited_entries != @as(usize, @intCast(wire.MAX_SKILL_CATALOG_TRAVERSAL_ENTRIES_V1)) or
        skill_catalog_handles.MAX_LIVE_SNAPSHOT_BYTES != @as(usize, @intCast(wire.MAX_SKILL_RUNTIME_RETAINED_SNAPSHOT_BYTES_V1)))
        @compileError("AgentCore wire and canonical Skill catalog limits must match");
    const canonical_reasons = std.meta.fields(skill_catalog.ResourceReason);
    const public_reasons = std.meta.fields(public_protocol.SkillCatalogResourceReason);
    if (canonical_reasons.len != public_reasons.len)
        @compileError("AgentCore public and canonical Skill resource reasons must match");
    for (canonical_reasons, public_reasons) |canonical, public| {
        if (!std.mem.eql(u8, canonical.name, public.name) or canonical.value != public.value)
            @compileError("AgentCore public and canonical Skill resource reason tags must match");
    }
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

const AbiMcpConnector = struct {
    descriptor: wire.McpConnectorV1,
    transport: mcp_negotiation.Transport,
    max_frame_bytes: u64,
    timeout_ms: u32,
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    fn create(
        descriptor: wire.McpConnectorV1,
        transport: mcp_negotiation.Transport,
        max_frame_bytes: u64,
        timeout_ms: u32,
    ) error{OutOfMemory}!*AbiMcpConnector {
        const self = allocator.create(AbiMcpConnector) catch
            return error.OutOfMemory;
        self.* = .{
            .descriptor = descriptor,
            .transport = transport,
            .max_frame_bytes = max_frame_bytes,
            .timeout_ms = timeout_ms,
        };
        descriptor.retain_connector.?(descriptor.ctx);
        return self;
    }

    fn connector(self: *AbiMcpConnector) mcp_runtime.Connector {
        return .{
            .ctx = self,
            .open_fn = open,
            .retain_fn = retain,
            .release_fn = release,
        };
    }

    fn retain(raw: *anyopaque) anyerror!void {
        const self: *AbiMcpConnector = @ptrCast(@alignCast(raw));
        const previous = self.refs.fetchAdd(1, .monotonic);
        if (previous == std.math.maxInt(u32)) {
            _ = self.refs.fetchSub(1, .monotonic);
            return error.ResourceLimit;
        }
    }

    fn release(raw: *anyopaque) void {
        const self: *AbiMcpConnector = @ptrCast(@alignCast(raw));
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous != 1) return;
        self.descriptor.release_connector.?(self.descriptor.ctx);
        allocator.destroy(self);
    }

    fn open(
        raw: *anyopaque,
        purpose: mcp_runtime.ConnectionPurpose,
        era: mcp_canonical.Era,
    ) anyerror!mcp_runtime.OpenOutcome {
        const self: *AbiMcpConnector = @ptrCast(@alignCast(raw));
        const callback = self.descriptor.open orelse return error.InvalidConnector;
        var connection_ctx: ?*anyopaque = null;
        const status = callback(
            self.descriptor.ctx,
            switch (purpose) {
                .disposable_probe => wire.MCP_CONNECTION_DISPOSABLE_PROBE,
                .actual => wire.MCP_CONNECTION_ACTUAL,
            },
            switch (era) {
                .modern_2026_07_28 => wire.MCP_ERA_2026_07_28,
                .classic_2025_11_25 => wire.MCP_ERA_2025_11_25,
                .classic_2025_06_18 => wire.MCP_ERA_2025_06_18,
            },
            self.timeout_ms,
            &connection_ctx,
        );
        if (status == wire.MCP_OPEN_OK) {
            const host_connection = connection_ctx orelse
                return error.InvalidConnectorResponse;
            const connection = allocator.create(AbiMcpConnection) catch {
                self.descriptor.close.?(self.descriptor.ctx, host_connection);
                return error.OutOfMemory;
            };
            connection.* = .{
                .descriptor = self.descriptor,
                .transport = self.transport,
                .max_frame_bytes = self.max_frame_bytes,
                .host_connection = host_connection,
            };
            self.descriptor.retain_connector.?(self.descriptor.ctx);
            return .{ .connection = connection.interface() };
        }
        if (connection_ctx) |unexpected| {
            self.descriptor.close.?(self.descriptor.ctx, unexpected);
            return error.InvalidConnectorResponse;
        }
        return switch (status) {
            wire.MCP_OPEN_TIMEOUT => .timeout,
            wire.MCP_OPEN_NETWORK_ERROR => .network_error,
            wire.MCP_OPEN_AUTH_ERROR => .auth_error,
            wire.MCP_OPEN_SERVER_ERROR => .server_error,
            wire.MCP_OPEN_CHILD_EXIT => .child_exit,
            else => error.HostConnectorFatal,
        };
    }
};

const AbiMcpConnection = struct {
    descriptor: wire.McpConnectorV1,
    transport: mcp_negotiation.Transport,
    max_frame_bytes: u64,
    host_connection: *anyopaque,

    fn interface(self: *AbiMcpConnection) mcp_runtime.Connection {
        return .{
            .ctx = self,
            .request_fn = request,
            .notify_fn = notify,
            .close_fn = close,
        };
    }

    fn request(
        raw: *anyopaque,
        response_allocator: std.mem.Allocator,
        request_json: []const u8,
        timeout_ms: u32,
        cancellation: mcp_runtime.Cancellation,
    ) anyerror!mcp_runtime.ExchangeOutcome {
        const self: *AbiMcpConnection = @ptrCast(@alignCast(raw));
        var cancellation_copy = cancellation;
        const public_cancellation = wire.McpCancellationV1{
            .struct_size = @sizeOf(wire.McpCancellationV1),
            .reserved0 = 0,
            .ctx = &cancellation_copy,
            .is_cancelled = cancellationPoll,
            .reserved = [_]u64{0} ** 2,
        };
        var response = wire.McpResponseV1{
            .struct_size = @sizeOf(wire.McpResponseV1),
            .http_status = 0,
            .body = .{ .ptr = null, .len = 0 },
            .reserved = [_]u64{0} ** 2,
        };
        const status = self.descriptor.request.?(
            self.descriptor.ctx,
            self.host_connection,
            view(request_json),
            timeout_ms,
            &public_cancellation,
            &response,
        );
        defer if (hasReleaseToken(response.body))
            self.descriptor.release_response.?(
                self.descriptor.ctx,
                self.host_connection,
                &response.body,
            );
        if (response.struct_size != @sizeOf(wire.McpResponseV1) or
            !allZero(response.reserved) or !canonicalOwned(response.body))
            return error.InvalidConnectorResponse;
        if (status == wire.MCP_EXCHANGE_RESPONSE) {
            const status_valid = switch (self.transport) {
                .stdio => response.http_status == 0,
                .streamable_http => response.http_status >= 200 and response.http_status <= 599,
            };
            if (!status_valid or response.body.len > self.max_frame_bytes or
                (response.body.len == 0 and self.transport == .stdio))
                return error.InvalidConnectorResponse;
            const source = try ownedSlice(response.body);
            const copied = response_allocator.dupe(u8, source) catch
                return error.OutOfMemory;
            return .{ .response = .{
                .http_status = response.http_status,
                .body = copied,
            } };
        }
        if (response.http_status != 0 or response.body.len != 0)
            return error.InvalidConnectorResponse;
        return switch (status) {
            wire.MCP_EXCHANGE_TIMEOUT => .timeout,
            wire.MCP_EXCHANGE_NETWORK_ERROR => .network_error,
            wire.MCP_EXCHANGE_AUTH_ERROR => .auth_error,
            wire.MCP_EXCHANGE_SERVER_ERROR => .server_error,
            wire.MCP_EXCHANGE_CHILD_EXIT => .child_exit,
            wire.MCP_EXCHANGE_CANCELLED => .cancelled,
            wire.MCP_EXCHANGE_INDETERMINATE => .indeterminate,
            else => error.HostConnectorFatal,
        };
    }

    fn notify(
        raw: *anyopaque,
        notification_json: []const u8,
        timeout_ms: u32,
        cancellation: mcp_runtime.Cancellation,
    ) anyerror!void {
        const self: *AbiMcpConnection = @ptrCast(@alignCast(raw));
        var cancellation_copy = cancellation;
        const public_cancellation = wire.McpCancellationV1{
            .struct_size = @sizeOf(wire.McpCancellationV1),
            .reserved0 = 0,
            .ctx = &cancellation_copy,
            .is_cancelled = cancellationPoll,
            .reserved = [_]u64{0} ** 2,
        };
        const status = self.descriptor.notify.?(
            self.descriptor.ctx,
            self.host_connection,
            view(notification_json),
            timeout_ms,
            &public_cancellation,
        );
        if (status != wire.MCP_NOTIFY_OK) return error.HostNotifyFailed;
    }

    fn close(raw: *anyopaque) void {
        const self: *AbiMcpConnection = @ptrCast(@alignCast(raw));
        self.descriptor.close.?(
            self.descriptor.ctx,
            self.host_connection,
        );
        self.descriptor.release_connector.?(self.descriptor.ctx);
        allocator.destroy(self);
    }

    fn cancellationPoll(raw: ?*const anyopaque) callconv(.c) u32 {
        const cancellation: *const mcp_runtime.Cancellation =
            @ptrCast(@alignCast(raw orelse return 1));
        return @intFromBool(cancellation.isCancelled());
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

fn createInitialMcpSelection(
    runtime: *AbiRuntime,
    selectors: []const mcp_session.Selector,
    mode: mcp_session.BuildMode,
) !?mcp_session.Selection {
    if (selectors.len == 0) return null;
    const manager = if (runtime.mcp_manager) |*value| value else {
        return error.InvalidMcpBinding;
    };
    const snapshot = try manager.retainCurrent();
    defer snapshot.release();
    return try mcp_session.Selection.init(allocator, snapshot, selectors, mode);
}

const AbiSession = struct {
    const CallState = enum { idle, running, compacting, mutating, checkpointing, destroying };

    callbacks: wire.SessionCallbacksV1,
    callback_status: std.atomic.Value(u32),
    facade_poisoned: std.atomic.Value(bool),
    core_session: *core.agent_session.AgentSession,
    /// Null in narrow ABI unit fakes that do not own a Core Session.
    lifecycle_session: ?*core.agent_session.AgentSession = null,
    runtime: ?*AbiRuntime = null,
    workspace_scope_id: [64]u8 = [_]u8{0} ** 64,
    skill_binding: ?SkillBinding = null,
    mcp_selection: ?mcp_session.Selection = null,
    /// Borrowed only while one synchronous Run is admitted. Permission uses
    /// it to resolve the model-facing alias back to canonical MCP identity.
    active_mcp_environment: ?*const mcp_session.Environment = null,
    /// The innermost synchronous fork projector supplies exact child
    /// tool-call identity to Permission provenance. Nested forks restore the
    /// outer projector when their own scope quiesces.
    active_permission_trace: ?*event_projection.Projector = null,
    /// Borrowed from the synchronous Run. Permission callbacks reserve a
    /// durable Session-rule delta through the same controller used by the
    /// Provider/Tool/MCP decorators before publishing allow_session or
    /// deny_session memory.
    active_budget_controller: ?*session_budget.Controller = null,
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
    authority_issues: ?session_authority.IssueLedger = null,
    permission_state: session_permission.State = .{
        .allocator = allocator,
        .policy_generation = 1,
    },
    permission_audit: ?session_permission.AuditTrail = null,
    permission_request_sequence: u64 = 0,
    pending_permission: ?PendingPermission = null,
    run_state_projector: run_state.Projector = undefined,
    /// A bounded RunState projection is an observation aid, not the run's
    /// execution channel.  Once its owned tool set cannot represent a new
    /// tool, stop projecting this run but keep delivering canonical events
    /// and let the synchronous RunResult close the run authoritatively.
    run_state_observation_disabled: bool = false,
    staged_permission_provenance: ?StagedPermissionProvenance = null,
    staged_permission_failure: u32 = wire.STATUS_OK,
    budget_state: session_budget.SessionState = .{
        .profile = .{},
    },
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

    /// One synchronous Permission check is followed by exactly one internal
    /// `policy_decision` event before the loop examines the next tool.  Keep
    /// the canonical receipt here until that existing event boundary delivers
    /// it through AgentSession's fatal-aware EventSink.
    const StagedPermissionProvenance = struct {
        model_tool_name: []const u8,
        source: session_permission.DecisionSource,
        matched_rule_id: ?session_permission.RuleId = null,
        session_id: core.session_id.SessionId,
        run_id: u64,
        /// Owned by the staged receipt. Callback requests are allocated from a
        /// short-lived response arena, so the exact identity must be retained
        /// until the corresponding policy event arrives.
        tool_call_id: ?[]u8 = null,
        request_id: ?session_permission.PermissionRequestId = null,
        tool: session_permission.ToolIdentity,
        arguments_digest: session_permission.ArgumentsDigest,
        policy_generation: u64,
        used_session_rule: bool = false,
        callback_outcome: ?session_permission.CallbackOutcome = null,
        response: ?session_permission.Response = null,
        prepared_audit: ?session_permission.OwnedProvenance = null,
    };

    fn clearStagedPermission(self: *AbiSession) void {
        if (self.staged_permission_provenance) |*staged| {
            if (staged.tool_call_id) |owned| allocator.free(owned);
            if (staged.prepared_audit) |*prepared| {
                if (self.permission_audit) |*audit|
                    audit.discard(prepared)
                else {
                    // The prepared receipt owns its strings independently of
                    // the trail. Recover safely even if a future lifecycle
                    // change violates the expected audit/staging coupling.
                    prepared.deinit(allocator);
                    self.recordCallbackStatus(wire.STATUS_INTERNAL_ERROR);
                }
            }
        }
        self.staged_permission_provenance = null;
        self.staged_permission_failure = wire.STATUS_OK;
    }

    fn permissionDecisionOverride(
        raw: *anyopaque,
        tool_name: []const u8,
        arguments_json: []const u8,
        imported: core.permission.ImportedPermissionDecision,
    ) ?core.permission.PermissionResult {
        const self: *AbiSession = @ptrCast(@alignCast(raw));
        self.pending_permission = null;
        const mcp_entry = if (self.active_mcp_environment) |mcp_bound|
            mcp_bound.findModelTool(tool_name)
        else
            null;
        const explicit_name_owned = if (mcp_entry) |entry|
            entry.permissionRuleName(allocator) catch return .deny
        else
            null;
        defer if (explicit_name_owned) |name| allocator.free(name);
        const explicit_name = explicit_name_owned orelse tool_name;
        const tool = self.permissionToolIdentity(tool_name) catch return .deny;
        const digest = session_permission.digestCanonicalArguments(
            allocator,
            arguments_json,
            .{},
        ) catch return .deny;
        if (mcp_entry != null) {
            const validation = self.active_mcp_environment.?.validateInvocation(
                tool_name,
                arguments_json,
            );
            switch (validation) {
                .valid => {},
                .invalid => |issue| {
                    self.stagePermissionDecision(tool_name, tool, digest, .{
                        .decision = .deny,
                        .source = .core_safety,
                    });
                    if (issue == .resource_limit) {
                        self.recordCallbackStatus(wire.STATUS_RESOURCE_LIMIT);
                        self.staged_permission_failure = wire.STATUS_RESOURCE_LIMIT;
                    }
                    return .deny;
                },
                .out_of_memory => {
                    self.stagePermissionDecision(tool_name, tool, digest, .{
                        .decision = .deny,
                        .source = .core_safety,
                    });
                    self.recordCallbackStatus(wire.STATUS_OUT_OF_MEMORY);
                    self.staged_permission_failure = wire.STATUS_OUT_OF_MEMORY;
                    return .deny;
                },
            }
        }
        var match_context = self.core_session.permission_ctx.match_ctx;
        if (match_context.alloc == null)
            match_context.alloc = self.core_session.permission_ctx.allocator;
        const imported_decision = imported.resolved();
        const imported_source = imported.source();
        const shared_source: ?session_permission.DecisionSource = switch (imported_source) {
            .core_safety => .core_safety,
            .active_skill => .active_skill,
            .session_memory => .session_deny,
            .none, .settings => null,
        };
        const is_shared_ceiling = shared_source != null;
        const explicit: session_permission.ExplicitAction = if (is_shared_ceiling)
            switch (imported_decision.?) {
                .deny => .deny,
                .ask => .ask,
                .allow => .allow,
            }
        else if (self.core_session.permission_ctx.settings != null)
            session_permission.evaluateExplicit(
                self.core_session.permission_ctx.settings,
                &match_context,
                explicit_name,
                arguments_json,
            )
        else if (imported_decision) |decision| switch (decision) {
            .deny => .deny,
            .ask => .ask,
            .allow => .allow,
        } else .undecided;
        const permission_mode = self.core_session.permission_ctx.modeValue();
        const external_fallback: session_permission.Decision = if (tool.namespace == .builtin)
            .ask
        else switch (permission_mode) {
            .plan, .dont_ask => .deny,
            .bypass_permissions, .bypass => .allow,
            .default, .accept_edits, .auto, .prompt => .ask,
        };
        var result = if (is_shared_ceiling)
            session_permission.DecisionResult{
                .decision = switch (imported_decision.?) {
                    .deny => .deny,
                    .ask => .ask,
                    .allow => .allow,
                },
                .source = shared_source.?,
            }
        else
            self.permission_state.decide(
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
        const delegates_builtin_classification = !suppress_prompt and
            result.source == .mode_fallback and
            tool.namespace == .builtin;
        self.stagePermissionDecision(
            tool_name,
            tool,
            digest,
            if (delegates_builtin_classification) .{
                .decision = result.decision,
                .source = .builtin_classification,
            } else result,
        );
        if (suppress_prompt) return .deny;
        // Built-ins retain the Core's read/edit/risk classification. Host and
        // MCP identities are intentionally unknown to that product-level
        // classifier, so AgentCore must finish their conservative mode
        // fallback here instead of letting an unknown alias become read-only.
        if (delegates_builtin_classification)
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
        if (self.active_mcp_environment) |mcp_bound|
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
        if (self.active_permission_trace) |trace|
            return trace.copyToolCallId(
                output_allocator,
                tool_name,
                arguments_json,
            ) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidIdentity => error.InvalidIdentity,
            };
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

    fn permissionForkOwner(self: *AbiSession) child_permission.Owner {
        return .{
            .parent = &self.core_session.permission_ctx,
            .ctx = self,
            .swap_trace_fn = swapPermissionTrace,
            .clear_pending_fn = clearPendingPermission,
        };
    }

    fn swapPermissionTrace(
        raw: *anyopaque,
        replacement: ?*event_projection.Projector,
    ) ?*event_projection.Projector {
        const self: *AbiSession = @ptrCast(@alignCast(raw));
        const previous = self.active_permission_trace;
        self.active_permission_trace = replacement;
        return previous;
    }

    fn clearPendingPermission(raw: *anyopaque) void {
        const self: *AbiSession = @ptrCast(@alignCast(raw));
        self.pending_permission = null;
    }

    fn stagePermissionDecision(
        self: *AbiSession,
        model_tool_name: []const u8,
        tool: session_permission.ToolIdentity,
        digest: session_permission.ArgumentsDigest,
        result: session_permission.DecisionResult,
    ) void {
        self.clearStagedPermission();
        if (self.permission_audit == null and self.callbacks.on_event == null) {
            return;
        }
        const run_id = self.core_session.active_run_id;
        if (run_id == 0) {
            return;
        }
        self.staged_permission_provenance = .{
            .model_tool_name = model_tool_name,
            .source = result.source,
            .matched_rule_id = result.matched_rule_id,
            .session_id = self.core_session.session_id,
            .run_id = run_id,
            .tool = tool,
            .arguments_digest = digest,
            .policy_generation = self.policy_generation,
            .used_session_rule = result.used_session_rule,
        };
    }

    fn publishStagedPermission(
        self: *AbiSession,
        session_id: core.session_id.SessionId,
        run_id: u64,
        event: core.protocol.ui_event.CoreEvent,
    ) bool {
        const policy = switch (event) {
            .policy_decision => |value| value,
            else => return true,
        };
        if (self.staged_permission_failure != wire.STATUS_OK) {
            self.staged_permission_failure = wire.STATUS_OK;
            return false;
        }
        var staged = self.staged_permission_provenance orelse return true;
        self.staged_permission_provenance = null;
        defer if (staged.tool_call_id) |owned| allocator.free(owned);
        defer if (staged.prepared_audit) |*prepared| {
            if (self.permission_audit) |*audit| audit.discard(prepared);
        };
        if (!std.mem.eql(u8, staged.session_id.asSlice(), session_id.asSlice()) or
            staged.run_id != run_id or
            !std.mem.eql(u8, staged.model_tool_name, policy.tool) or
            (staged.tool_call_id != null and
                !std.mem.eql(u8, staged.tool_call_id.?, policy.id)))
        {
            self.recordCallbackStatus(wire.STATUS_INTERNAL_ERROR);
            return false;
        }
        const provenance = session_permission.Provenance{
            .decision = if (policy.allowed) .allow else .deny,
            .source = staged.source,
            .matched_rule_id = staged.matched_rule_id,
            .session_id = session_id,
            .run_id = run_id,
            .tool_call_id = policy.id,
            .request_id = staged.request_id,
            .tool = staged.tool,
            .arguments_digest = staged.arguments_digest,
            .policy_generation = staged.policy_generation,
            .used_session_rule = staged.used_session_rule,
            .callback_outcome = staged.callback_outcome,
            .response = staged.response,
        };
        if (self.permission_audit) |*audit| {
            if (staged.prepared_audit) |*prepared| {
                prepared.decision = provenance.decision;
                audit.commit(prepared);
                staged.prepared_audit = null;
            } else audit.append(provenance) catch |err| {
                self.recordCallbackStatus(if (err == error.OutOfMemory)
                    wire.STATUS_OUT_OF_MEMORY
                else
                    wire.STATUS_INTERNAL_ERROR);
                return false;
            };
        }
        self.emitPermissionProvenance(provenance) catch return false;
        return true;
    }

    fn emitPermissionProvenance(
        self: *AbiSession,
        provenance: session_permission.Provenance,
    ) session_permission.Error!void {
        const callback = self.callbacks.on_event orelse return;
        const binding_hex = std.fmt.bytesToHex(provenance.tool.binding, .lower);
        const digest_hex = std.fmt.bytesToHex(provenance.arguments_digest, .lower);
        var matched_rule_hex: [session_permission.RULE_ID_BYTES * 2]u8 = undefined;
        const matched_rule_id: ?[]const u8 = if (provenance.matched_rule_id) |value| blk: {
            matched_rule_hex = std.fmt.bytesToHex(value, .lower);
            break :blk &matched_rule_hex;
        } else null;
        var request_hex: [session_permission.REQUEST_ID_BYTES * 2]u8 = undefined;
        const request_id: ?[]const u8 = if (provenance.request_id) |value| blk: {
            request_hex = std.fmt.bytesToHex(value, .lower);
            break :blk &request_hex;
        } else null;
        const dto = public_protocol.PermissionProvenance{
            .decision = switch (provenance.decision) {
                .deny => .deny,
                .ask => .ask,
                .allow => .allow,
            },
            .source = switch (provenance.source) {
                .core_safety => .core_safety,
                .active_skill => .active_skill,
                .explicit_deny => .explicit_deny,
                .session_deny => .session_deny,
                .explicit_ask => .explicit_ask,
                .explicit_allow => .explicit_allow,
                .session_allow => .session_allow,
                .builtin_classification => .builtin_classification,
                .mode_fallback => .mode_fallback,
                .callback => .callback,
            },
            .matched_rule_id = matched_rule_id,
            .session_id = provenance.session_id.asSlice(),
            .run_id = provenance.run_id,
            .tool_call_id = provenance.tool_call_id,
            .request_id = request_id,
            .tool = .{
                .namespace = switch (provenance.tool.namespace) {
                    .builtin => .builtin,
                    .host => .host,
                    .mcp => .mcp,
                },
                .name = provenance.tool.name,
                .binding = &binding_hex,
            },
            .canonical_arguments_digest = &digest_hex,
            .policy_generation = provenance.policy_generation,
            .used_session_rule = provenance.used_session_rule,
            .callback_outcome = if (provenance.callback_outcome) |value| switch (value) {
                .answered => .answered,
                .user_cancelled => .user_cancelled,
                .unavailable => .unavailable,
                .contract_failure => .contract_failure,
            } else null,
            .response = if (provenance.response) |value| switch (value) {
                .deny_once => .deny_once,
                .deny_session => .deny_session,
                .allow_once => .allow_once,
                .allow_session => .allow_session,
            } else null,
        };
        const json = std.json.Stringify.valueAlloc(
            allocator,
            public_protocol.CoreEvent{ .permission_provenance = dto },
            .{},
        ) catch {
            self.recordCallbackStatus(wire.STATUS_OUT_OF_MEMORY);
            return error.OutOfMemory;
        };
        defer allocator.free(json);
        const identity = core.agent_session.RunIdentity{
            .session_id = provenance.session_id,
            .run_id = provenance.run_id,
        };
        const run = self.runContext(&identity);
        if (callback(self.callbacks.ctx, &run, view(json)) != wire.EVENT_CONTINUE) {
            self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
            return error.InvalidResponse;
        }
    }

    fn handle(self: *AbiSession) *wire.SessionHandle {
        return @ptrCast(self);
    }

    fn runContext(self: *AbiSession, identity: *const core.agent_session.RunIdentity) wire.RunContextV1 {
        return makeRunContext(self.handle(), identity);
    }

    fn emitRunStateSnapshot(self: *AbiSession, session_id: core.session_id.SessionId, run_id: u64) bool {
        const callback = self.callbacks.on_event orelse return true;
        const snapshot = self.run_state_projector.nextSnapshot() catch {
            self.recordCallbackStatus(wire.STATUS_OUT_OF_MEMORY);
            return false;
        };
        defer allocator.free(snapshot.in_flight_tools);
        const json = std.json.Stringify.valueAlloc(
            allocator,
            public_protocol.CoreEvent{ .run_state = snapshot },
            .{},
        ) catch {
            self.recordCallbackStatus(wire.STATUS_OUT_OF_MEMORY);
            return false;
        };
        defer allocator.free(json);
        const identity = core.agent_session.RunIdentity{ .session_id = session_id, .run_id = run_id };
        const run = self.runContext(&identity);
        if (callback(self.callbacks.ctx, &run, view(json)) != wire.EVENT_CONTINUE) {
            self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
            self.core_session.noteCallbackFailure();
            return false;
        }
        return true;
    }

    fn observeRunState(self: *AbiSession, session_id: core.session_id.SessionId, run_id: u64, event: core.protocol.ui_event.CoreEvent) bool {
        if (self.run_state_projector.run_id != run_id) {
            self.run_state_observation_disabled = false;
            self.run_state_projector.begin(run_id);
            if (!self.emitRunStateSnapshot(session_id, run_id)) return false;
        }
        if (self.run_state_observation_disabled) return true;
        var changed = false;
        switch (event) {
            .progress => |value| {
                changed = self.run_state_projector.observeProgress(value.turn, value.tool_calls);
                if (self.run_state_projector.inFlightCount() == 0)
                    changed = self.run_state_projector.setPhase(.generating) or changed;
            },
            .stream_begin => {
                if (self.run_state_projector.inFlightCount() == 0)
                    changed = self.run_state_projector.setPhase(.generating);
            },
            .tool_start => |value| {
                const added = self.run_state_projector.addTool(value.id, value.name) catch |err| switch (err) {
                    error.ResourceLimit => {
                        self.run_state_observation_disabled = true;
                        return true;
                    },
                    error.OutOfMemory => {
                        self.recordCallbackStatus(wire.STATUS_OUT_OF_MEMORY);
                        return false;
                    },
                };
                changed = self.run_state_projector.setPhase(.executing_tools) or added;
            },
            .tool_result => |value| {
                const removed = self.run_state_projector.removeTool(value.id);
                changed = removed;
                if (self.run_state_projector.inFlightCount() == 0)
                    changed = self.run_state_projector.setPhase(.generating) or changed;
            },
            .retry_notice => {
                changed = self.run_state_projector.setPhase(.retrying);
            },
            .ui_request_pending => {
                changed = self.run_state_projector.setPhase(.waiting_ui);
            },
            .ui_request_resolved => {
                changed = if (self.run_state_projector.inFlightCount() > 0)
                    self.run_state_projector.setPhase(.executing_tools)
                else
                    self.run_state_projector.setPhase(.generating);
            },
            .diag_compact_request => |value| {
                _ = value;
            },
            .diag_compact_begin => {
                changed = self.run_state_projector.setPhase(.compacting);
            },
            .diag_compact_end => {
                if (self.run_state_projector.phase == .compacting)
                    changed = self.run_state_projector.setPhase(.generating);
            },
            .diag_run_end => |value| {
                if (self.run_state_projector.setPhase(.finalizing)) {
                    if (!self.emitRunStateSnapshot(session_id, run_id)) return false;
                }
                const terminal: public_protocol.RunStatePhase = if (std.mem.eql(u8, value.stop_reason_name, "aborted"))
                    .aborted
                else if (std.mem.eql(u8, value.stop_reason_name, "end_turn") or
                    std.mem.eql(u8, value.stop_reason_name, "max_turns"))
                    .completed
                else
                    .failed;
                self.run_state_projector.closeForTerminal(terminal);
                return self.emitRunStateSnapshot(session_id, run_id);
            },
            else => {},
        }
        if (!changed) return true;
        return self.emitRunStateSnapshot(session_id, run_id);
    }

    fn startRunState(self: *AbiSession, session_id: core.session_id.SessionId, run_id: u64) bool {
        // `startRunState` establishes the new run id before the first event
        // reaches observeRunState, so the run boundary must reset observation
        // degradation here rather than relying on the projector mismatch path.
        self.run_state_observation_disabled = false;
        self.run_state_projector.begin(run_id);
        return self.emitRunStateSnapshot(session_id, run_id);
    }

    fn emitPoisonedRunState(self: *AbiSession, run_id: u64) void {
        if (self.callback_status.load(.acquire) != wire.STATUS_OK) return;
        if (self.run_state_observation_disabled) return;
        self.run_state_projector.closeForTerminal(.poisoned);
        _ = self.emitRunStateSnapshot(self.core_session.session_id, run_id);
    }

    fn emit(raw: *anyopaque, session_id: core.session_id.SessionId, run_id: u64, event: core.protocol.ui_event.CoreEvent) bool {
        const self: *AbiSession = @ptrCast(@alignCast(raw));
        if (!self.publishStagedPermission(session_id, run_id, event))
            return false;
        if (!self.observeRunState(session_id, run_id, event))
            return false;
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

    fn emitUiPending(self: *AbiSession, tool_use_id: []const u8, request_json: []const u8) void {
        const session = self.lifecycle_session orelse return;
        session.emitLifecycleEvent(.{ .ui_request_pending = .{
            .tool_use_id = tool_use_id,
            .request_json = request_json,
        } });
    }

    fn emitUiResolved(self: *AbiSession) void {
        const session = self.lifecycle_session orelse return;
        session.emitLifecycleEvent(.ui_request_resolved);
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
            .model_tool_name = tool_name,
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
        self.emitUiPending(request.tool_call_id, request_json);
        defer self.emitUiResolved();
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
                        // Prepare the receipt before mutating authority.  The
                        // following policy event supplies the final execution
                        // decision and atomically commits the receipt.
                        try self.recordPermissionCallback(
                            request,
                            .answered,
                            permission_response,
                        );
                        _ = self.rememberPermissionResponseBudgeted(
                            permission_response,
                            rule_candidate,
                        ) catch |err| {
                            if (err == error.BudgetExhausted) return err;
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
                if (permission_response == .allow_once or
                    permission_response == .deny_once)
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

    fn rememberPermissionResponseBudgeted(
        self: *AbiSession,
        response: session_permission.Response,
        candidate: session_permission.RuleCandidate,
    ) !session_permission.RememberResult {
        var durable_reservation: ?session_budget.DurableReservation = null;
        defer if (durable_reservation) |*reservation| reservation.release();
        if (self.active_budget_controller) |controller| {
            const durable_delta = try session_permission.checkpointRuleDeltaBytes(
                candidate.tool,
            );
            durable_reservation = try controller.beginDurableDelta(durable_delta);
        }
        const remembered = try self.permission_state.remember(
            response,
            candidate,
            self.policy_generation,
        );
        if (durable_reservation) |*reservation| switch (remembered) {
            .added => reservation.commit(),
            .already_present => reservation.release(),
        };
        return remembered;
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
        self.emitUiPending("", request_json);
        defer self.emitUiResolved();
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
        const decision: session_permission.Decision = switch (response orelse
            .deny_once) {
            .allow_once, .allow_session => .allow,
            .deny_once, .deny_session => .deny,
        };
        const provenance = session_permission.Provenance{
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
        };
        self.clearStagedPermission();
        const staged_tool_call_id = allocator.dupe(u8, request.tool_call_id) catch {
            self.recordCallbackStatus(wire.STATUS_OUT_OF_MEMORY);
            self.staged_permission_failure = wire.STATUS_OUT_OF_MEMORY;
            return error.OutOfMemory;
        };
        errdefer allocator.free(staged_tool_call_id);
        var prepared_audit: ?session_permission.OwnedProvenance = null;
        if (self.permission_audit) |*audit| {
            prepared_audit = audit.prepare(provenance) catch |err| {
                const status = if (err == error.OutOfMemory)
                    wire.STATUS_OUT_OF_MEMORY
                else
                    wire.STATUS_INTERNAL_ERROR;
                self.recordCallbackStatus(status);
                self.staged_permission_failure = status;
                return err;
            };
        }
        self.staged_permission_provenance = .{
            .model_tool_name = request.model_tool_name,
            .source = .callback,
            .session_id = request.session_id,
            .run_id = request.run_id,
            .tool_call_id = staged_tool_call_id,
            .request_id = request.request_id,
            .tool = request.tool,
            .arguments_digest = request.arguments_digest,
            .policy_generation = request.policy_generation,
            .callback_outcome = callback_outcome,
            .response = response,
            .prepared_audit = prepared_audit,
        };
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
        std.debug.assert(kind != .none);
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
            .budget_exhausted, .resource_limit => if (self.last_terminal_id == lease.last_run_id) return .{
                .kind = self.last_terminal_kind,
                .id = self.last_terminal_id,
            },
            .none => {},
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

    /// Measure the exact checkpoint that would be emitted for the current
    /// committed Session. This is usable while the facade Run gate is held as
    /// long as no Core Run is active; no sink, generation commit or hidden
    /// compaction occurs.
    fn measureDurableUsage(self: *AbiSession) !session_checkpoint.Usage {
        var lease = try self.core_session.snapshotCommittedForRunMeasurement();
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
        const mcp_state = try mcp_checkpoint.encodeSelection(
            allocator,
            if (self.mcp_selection) |*selection| selection else null,
        );
        defer allocator.free(mcp_state);
        const terminal = self.terminalForCheckpoint(&lease);
        return session_checkpoint.measureSnapshot(.{
            .session_id = lease.session_id,
            .checkpoint_generation = self.checkpoint_generation +| 1,
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
        }, self.budget_state.profile.checkpointLimits());
    }

    fn preflightRootRecords(
        self: *AbiSession,
        records: []const []const u8,
    ) !session_budget.Preflight {
        const usage = try self.measureDurableUsage();
        try self.budget_state.updateUsage(usage.total_bytes);
        return session_budget.preflight(
            self.budget_state.profile,
            usage.total_bytes,
            records,
        ) catch |err| switch (err) {
            error.BudgetRequired => {
                self.budget_state.recordRequired(
                    self.budget_state.profile.hard_bytes +| 1,
                );
                return error.CheckpointBudgetRequired;
            },
            else => return err,
        };
    }

    fn finishBudgetedRun(
        self: *AbiSession,
        run_id: u64,
        controller: *session_budget.Controller,
    ) !session_budget.Outcome {
        const outcome = controller.outcome();
        const required = controller.requiredBytes();
        const terminal = switch (outcome) {
            .budget_exhausted => session_checkpoint.TerminalKind.budget_exhausted,
            .resource_limit => session_checkpoint.TerminalKind.resource_limit,
            .none, .budget_required => session_checkpoint.TerminalKind.run,
        };
        if (outcome == .budget_exhausted or outcome == .resource_limit) {
            const marker = if (outcome == .budget_exhausted)
                session_budget.BUDGET_EXHAUSTED_MARKER
            else
                session_budget.RESOURCE_LIMIT_MARKER;
            self.core_session.conversation.appendText(.assistant, marker) catch |err| {
                // The admitted Run has already committed its safe prefix. If
                // the bounded terminal cannot be published, retry semantics
                // are ambiguous; fail closed instead of returning idle.
                self.facade_poisoned.store(true, .release);
                return err;
            };
        }
        self.recordTerminal(terminal, run_id);
        const usage = self.measureDurableUsage() catch |err| {
            self.facade_poisoned.store(true, .release);
            return err;
        };
        self.budget_state.recordRun(outcome, required, usage.total_bytes) catch |err| {
            self.facade_poisoned.store(true, .release);
            return err;
        };
        return outcome;
    }

    /// Reconcile an error path only when Core has already consumed this Run
    /// and returned to an inspectable idle state. Pre-admission errors have no
    /// Run state to record; poisoned Runs remain terminal and cannot expose a
    /// misleading partial budget snapshot.
    fn reconcileBudgetedRunError(
        self: *AbiSession,
        run_id: u64,
        controller: *session_budget.Controller,
    ) void {
        if (self.core_session.isPoisoned()) return;
        var lease = self.core_session.snapshotCommittedForRunMeasurement() catch return;
        const run_was_consumed = lease.last_run_id == run_id;
        lease.deinit();
        if (!run_was_consumed) return;
        _ = self.finishBudgetedRun(run_id, controller) catch {
            self.facade_poisoned.store(true, .release);
        };
    }

    /// Explicit compact remains a separate idle activity. It borrows a
    /// budgeted Provider so an oversized summary cannot be published and does
    /// not hide compaction inside Run commit.
    fn compactBudgeted(
        self: *AbiSession,
        operation_id: u64,
    ) !core.compact_kernel.Report {
        return self.compactBudgetedUsingProvider(
            operation_id,
            self.core_session.provider.provider(),
        );
    }

    fn compactBudgetedUsingProvider(
        self: *AbiSession,
        operation_id: u64,
        base_provider: core.api_provider.Provider,
    ) !core.compact_kernel.Report {
        const initial_usage = try self.measureDurableUsage();
        try self.budget_state.updateUsage(initial_usage.total_bytes);
        // Compact is a replacement transaction, not a Run append. Provider
        // request/result caps still apply, but the live Conversation's current
        // bytes must not be counted again as if the summary were appended.
        var controller = session_budget.Controller.init(
            allocator,
            self.budget_state.profile,
            .{
                .input_delta_bytes = 0,
                .projected_usage_bytes = 0,
                .minimum_required_bytes = 0,
            },
        );
        var budget_provider = session_budget.BudgetedProvider{
            .allocator = allocator,
            .controller = &controller,
            .base = base_provider,
        };

        var lease = try self.core_session.snapshotCommitted();
        const checkpoint_session_id = lease.session_id;
        const checkpoint_last_run_id = lease.last_run_id;
        const checkpoint_model = lease.model;
        lease.deinit();
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
        const mcp_state = try mcp_checkpoint.encodeSelection(
            allocator,
            if (self.mcp_selection) |*selection| selection else null,
        );
        defer allocator.free(mcp_state);

        const CompactGuard = struct {
            controller: *session_budget.Controller,
            profile: session_budget.Profile,
            session_id: core.session_id.SessionId,
            checkpoint_generation: u64,
            last_run_id: u64,
            compact_id: u64,
            model: []const u8,
            policy_generation: u64,
            catalog_generation: u64,
            skill_state: []const u8,
            permission_state: []const u8,
            mcp_state: []const u8,

            fn allows(
                raw: *anyopaque,
                replacement: *const core.conversation.Conversation,
            ) bool {
                const guard: *@This() = @ptrCast(@alignCast(raw));
                if (guard.controller.outcome() != .none) return false;
                const usage = session_checkpoint.measureSnapshot(.{
                    .session_id = guard.session_id,
                    .checkpoint_generation = guard.checkpoint_generation,
                    .last_run_id = guard.last_run_id,
                    .last_compact_id = guard.compact_id,
                    .terminal_kind = .compact,
                    .terminal_id = guard.compact_id,
                    .model = guard.model,
                    .conversation = replacement,
                    .policy_generation = guard.policy_generation,
                    .catalog_generation = guard.catalog_generation,
                    .authority = .{
                        .skill = guard.skill_state,
                        .permission = guard.permission_state,
                        .mcp = guard.mcp_state,
                    },
                }, guard.profile.checkpointLimits()) catch {
                    guard.controller.failReplacementBudget(
                        guard.profile.hard_bytes +| 1,
                    );
                    return false;
                };
                if (usage.total_bytes > guard.profile.hard_bytes) {
                    guard.controller.failReplacementBudget(usage.total_bytes);
                    return false;
                }
                return true;
            }
        };
        var compact_guard = CompactGuard{
            .controller = &controller,
            .profile = self.budget_state.profile,
            .session_id = checkpoint_session_id,
            .checkpoint_generation = self.checkpoint_generation +| 1,
            .last_run_id = checkpoint_last_run_id,
            .compact_id = operation_id,
            .model = checkpoint_model,
            .policy_generation = self.policy_generation,
            .catalog_generation = self.catalog_generation,
            .skill_state = skill_state,
            .permission_state = permission_state,
            .mcp_state = mcp_state,
        };
        const report = try self.core_session.compactUsingBorrowedProvider(
            operation_id,
            .{ .commit_guard = .{
                .ctx = &compact_guard,
                .allowFn = CompactGuard.allows,
            } },
            budget_provider.provider(),
        );
        self.recordTerminal(.compact, operation_id);
        const usage = self.measureDurableUsage() catch |err| {
            self.facade_poisoned.store(true, .release);
            return err;
        };
        self.budget_state.recordRun(
            controller.outcome(),
            controller.requiredBytes(),
            usage.total_bytes,
        ) catch |err| {
            self.facade_poisoned.store(true, .release);
            return err;
        };
        return report;
    }

    /// Admission for an idle mutation that replaces one canonical checkpoint
    /// section (or the model string) without changing any other durable byte.
    /// The caller publishes only after this returns and then commits the exact
    /// projected usage with no fallible post-publication work.
    fn admitDurableReplacement(
        self: *AbiSession,
        current_bytes: u64,
        replacement_bytes: u64,
    ) !u64 {
        const usage = try self.measureDurableUsage();
        if (current_bytes > usage.total_bytes) return error.InvalidSessionState;
        const without_current = usage.total_bytes - current_bytes;
        const projected = std.math.add(
            u64,
            without_current,
            replacement_bytes,
        ) catch return error.ResourceLimit;
        _ = session_budget.preflightProjected(
            self.budget_state.profile,
            projected,
            0,
            0,
        ) catch |err| switch (err) {
            error.BudgetRequired => {
                self.budget_state.recordRequired(projected);
                return error.CheckpointBudgetRequired;
            },
            else => return err,
        };
        return projected;
    }

    fn commitDurableReplacement(self: *AbiSession, projected: u64) void {
        std.debug.assert(projected <= self.budget_state.profile.hard_bytes);
        self.budget_state.durable_usage_bytes = projected;
        self.budget_state.last_outcome = .none;
        self.budget_state.required_bytes = 0;
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
        const bounded_limits = try self.budget_state.profile.boundCheckpointLimits(
            limits,
        );

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
        const mcp_state = try mcp_checkpoint.encodeSelection(
            allocator,
            if (self.mcp_selection) |*selection| selection else null,
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
        }, bounded_limits, sink);
        self.commitCheckpointGeneration(next_generation);
        self.budget_state.commitVerifiedUsage(report.total_bytes);
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
        var description_arena = std.heap.ArenaAllocator.init(description_allocator);
        errdefer description_arena.deinit();
        const a = description_arena.allocator();
        const model = a.dupe(u8, lease.model) catch
            return error.OutOfMemory;
        const mcp_count = if (self.mcp_selection) |*selection|
            selection.entries.len
        else
            0;
        const mcp_tools = a.alloc(
            session_authority.McpToolDescription,
            mcp_count,
        ) catch return error.OutOfMemory;
        if (self.mcp_selection) |*selection| {
            for (selection.entries, mcp_tools) |entry, *description| {
                description.* = .{
                    .model_name = a.dupe(u8, entry.model_name) catch
                        return error.OutOfMemory,
                    .namespace = a.dupe(u8, entry.namespace) catch
                        return error.OutOfMemory,
                    .canonical_name = a.dupe(
                        u8,
                        entry.tool_name,
                    ) catch return error.OutOfMemory,
                    .server_binding_identity = entry.server_binding_identity,
                    .schema_fingerprint = entry.schema_fingerprint,
                    .permission_binding = entry.permissionIdentity().binding,
                    .era = entry.era,
                };
            }
        }
        const authority_issues = try session_authority.cloneIssues(
            a,
            if (self.authority_issues) |*issues| issues.items else &.{},
        );
        return .{
            .arena = description_arena,
            .session_id = lease.session_id,
            .origin = self.logical_origin,
            .lifecycle = if (self.facade_poisoned.load(.acquire)) .poisoned else .idle,
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
            .mcp_selection_fingerprint = if (self.mcp_selection) |*selection|
                selection.selection_fingerprint
            else
                [_]u8{0} ** 32,
            .mcp_tools = mcp_tools,
            .budget = self.budget_state.describe(),
            .authority_issues = authority_issues,
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

            const current_state = try session_authority.encodeSkillState(
                allocator,
                if (self.skill_binding) |*binding| binding.snapshot() else null,
                if (self.skill_binding) |*binding| &binding.selection else null,
            );
            defer allocator.free(current_state);
            const replacement_state = try session_authority.encodeSkillState(
                allocator,
                replacement_cell.snapshot,
                &replacement_selection,
            );
            defer allocator.free(replacement_state);
            const projected = try self.admitDurableReplacement(
                current_state.len,
                replacement_state.len,
            );

            const previous = self.skill_binding;
            self.skill_binding = .{
                .cell = replacement_cell,
                .selection = replacement_selection,
            };
            if (previous) |binding_value| {
                var binding = binding_value;
                binding.deinit(&runtime.catalogs);
            }
            self.commitDurableReplacement(projected);
            return;
        }

        const snapshot = if (self.skill_binding) |*binding|
            binding.snapshot()
        else
            return error.SkillCatalogNotBound;
        var replacement_selection = try skill_availability.Selection.init(
            allocator,
            snapshot,
            spec,
        );
        errdefer replacement_selection.deinit();
        const current_state = try session_authority.encodeSkillState(
            allocator,
            snapshot,
            &self.skill_binding.?.selection,
        );
        defer allocator.free(current_state);
        const replacement_state = try session_authority.encodeSkillState(
            allocator,
            snapshot,
            &replacement_selection,
        );
        defer allocator.free(replacement_state);
        const projected = try self.admitDurableReplacement(
            current_state.len,
            replacement_state.len,
        );
        const previous_selection = self.skill_binding.?.selection;
        self.skill_binding.?.selection = replacement_selection;
        var previous = previous_selection;
        previous.deinit();
        self.commitDurableReplacement(projected);
    }

    /// AgentCore Session mutation admitted through the common idle gate.
    fn setModel(self: *AbiSession, model: []const u8) !void {
        if (self.facade_poisoned.load(.acquire))
            return error.InvalidSessionState;
        if (!self.tryBeginMutation()) return error.SessionBusy;
        defer self.finishMutation();
        try self.setModelAdmitted(model);
    }

    fn setModelAdmitted(self: *AbiSession, model: []const u8) !void {
        const projected = try self.admitDurableReplacement(
            self.core_session.model.len,
            model.len,
        );
        try self.core_session.setModel(model);
        self.commitDurableReplacement(projected);
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
        const current_state = try session_authority.encodePermissionState(
            allocator,
            self.core_session.permission_ctx.modeValue(),
            &self.permission_state,
            self.policy_fingerprint,
        );
        defer allocator.free(current_state);
        var replacement_permission = try session_permission.State.init(
            allocator,
            next_generation,
        );
        defer replacement_permission.deinit();
        const replacement_state = try session_authority.encodePermissionState(
            allocator,
            self.core_session.permission_ctx.modeValue(),
            &replacement_permission,
            next_fingerprint,
        );
        defer allocator.free(replacement_state);
        const projected = try self.admitDurableReplacement(
            current_state.len,
            replacement_state.len,
        );
        try self.core_session.updatePermissionRules(input);
        self.permission_state.replaceGeneration(next_generation) catch
            unreachable;
        self.policy_generation = next_generation;
        self.policy_fingerprint = next_fingerprint;
        self.pending_permission = null;
        self.commitDurableReplacement(projected);
    }

    /// Replace the Session's value-only MCP selection at the common idle
    /// mutation boundary. A temporary View validates the selection against
    /// the current catalog, but the Session does not retain that generation.
    fn updateMcpSelection(
        self: *AbiSession,
        selectors: []const mcp_session.Selector,
        mode: mcp_session.BuildMode,
    ) !void {
        if (self.facade_poisoned.load(.acquire)) return error.InvalidSessionState;
        if (!self.tryBeginMutation()) return error.SessionBusy;
        defer self.finishMutation();
        if (selectors.len == 0 and self.mcp_selection == null) return;
        const runtime_owner = self.runtime orelse return error.InvalidSessionState;
        const manager = if (runtime_owner.mcp_manager) |*value| value else return error.InvalidMcpBinding;
        const snapshot = try manager.retainCurrent();
        defer snapshot.release();
        var replacement_view = try mcp_session.View.init(
            allocator,
            snapshot,
            selectors,
            mode,
        );
        defer replacement_view.deinit();
        var replacement = try mcp_session.Selection.fromView(
            allocator,
            &replacement_view,
        );
        var replacement_live = true;
        defer if (replacement_live) replacement.deinit();

        const base_definitions = self.core_session.tools.definitions;
        const names = try allocator.alloc(
            []const u8,
            base_definitions.len + replacement_view.entries.len,
        );
        defer allocator.free(names);
        for (base_definitions, names[0..base_definitions.len]) |definition, *name|
            name.* = definition.name;
        for (replacement_view.entries, names[base_definitions.len..]) |entry, *name|
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

        const resolver_context = RestorePermissionResolver{
            .runtime = runtime_owner,
            .allowed_tools = names[0..base_definitions.len],
            .mcp_view = &replacement_view,
        };
        var prepared_permission = try self.permission_state.prepareInvalidation(
            .mcp,
            resolver_context.interface(),
        );
        defer prepared_permission.deinit();

        const current_mcp_state = try mcp_checkpoint.encodeSelection(
            allocator,
            if (self.mcp_selection) |*selection| selection else null,
        );
        defer allocator.free(current_mcp_state);
        const replacement_mcp_state = try mcp_checkpoint.encodeSelection(
            allocator,
            &replacement,
        );
        defer allocator.free(replacement_mcp_state);
        const current_permission_state = try session_authority.encodePermissionState(
            allocator,
            self.core_session.permission_ctx.modeValue(),
            &self.permission_state,
            self.policy_fingerprint,
        );
        defer allocator.free(current_permission_state);
        const replacement_permission_state = try session_authority.encodePermissionState(
            allocator,
            self.core_session.permission_ctx.modeValue(),
            &prepared_permission.state,
            self.policy_fingerprint,
        );
        defer allocator.free(replacement_permission_state);
        const current_bytes = std.math.add(
            u64,
            current_mcp_state.len,
            current_permission_state.len,
        ) catch return error.ResourceLimit;
        const replacement_bytes = std.math.add(
            u64,
            replacement_mcp_state.len,
            replacement_permission_state.len,
        ) catch return error.ResourceLimit;
        const projected = try self.admitDurableReplacement(
            current_bytes,
            replacement_bytes,
        );

        var previous_selection = self.mcp_selection;
        const previous_root = self.policy_root;
        self.mcp_selection = replacement;
        replacement_live = false;
        self.policy_root = next_root;
        next_root_live = false;
        self.catalog_generation = self.mcp_selection.?.catalog_generation;
        self.pending_permission = null;
        self.permission_state.commitPrepared(&prepared_permission.state);

        const stale_grants = prepared_permission.invalidated;
        self.invalidated_mcp_bindings +|= stale_grants +| self.mcp_selection.?.invalidated;
        if (stale_grants != 0 or self.mcp_selection.?.invalidated != 0)
            self.restore_health = .degraded;
        if (previous_root) |root| root.release();
        if (previous_selection) |*old| old.deinit();
        self.commitDurableReplacement(projected);
    }

    /// Resolve the Session's copied selectors against the latest published
    /// Runtime generation. The returned View owns the generation lease for
    /// exactly one synchronous Run.
    fn materializeMcpRunView(self: *AbiSession) !?mcp_session.View {
        const selection = if (self.mcp_selection) |*value| value else return null;
        if (selection.selectors.len == 0) return null;
        const runtime_owner = self.runtime orelse return error.InvalidSessionState;
        const manager = if (runtime_owner.mcp_manager) |*value| value else return error.InvalidMcpBinding;
        const snapshot = try manager.retainCurrent();
        defer snapshot.release();
        return try selection.materialize(allocator, snapshot);
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
        if (!skill_catalog.isLowerHex64(catalog_revision))
            return error.InvalidCatalogRevision;
        if (!std.mem.eql(u8, &binding.snapshot().revision, catalog_revision))
            return error.StaleCatalog;
        if (!skill_catalog.isLowerHex64(skill_id)) return error.InvalidSkillId;
        const public_record = binding.snapshot().findByExecutionId(skill_id) orelse
            return error.SkillNotFound;
        if (!binding.view().isEnabled(binding.snapshot(), public_record))
            return error.SkillDisabled;
        var plan = try skill_activation.prepare(
            allocator,
            binding.snapshot(),
            catalog_revision,
            &public_record.skill_id,
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

        // The canonical invocation record is the exact, deterministic part of
        // a typed Skill root input. Reserve it through the same pre-admission
        // path as Text. Effectful body rendering remains after Core admission
        // and is atomically reconciled before Conversation mutation.
        const invocation_record = try canonicalInvocationRecord(
            allocator,
            &plan,
        );
        defer allocator.free(invocation_record);
        const preflight = try self.preflightRootRecords(&.{invocation_record});
        var budget_controller = session_budget.Controller.init(
            allocator,
            self.budget_state.profile,
            preflight,
        );
        errdefer self.reconcileBudgetedRunError(run_id, &budget_controller);
        var budget_provider = session_budget.BudgetedProvider{
            .allocator = allocator,
            .controller = &budget_controller,
            .base = self.core_session.provider.provider(),
        };
        if (self.active_budget_controller != null)
            return error.InvalidSessionState;
        self.active_budget_controller = &budget_controller;
        defer self.active_budget_controller = null;

        const execution = switch (try self.admitMaterializedSkillBudgeted(
            materializations,
            run_id,
            &plan,
            root_frame,
            &budget_controller,
            &budget_provider,
            invocation_record,
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
        _ = try self.finishBudgetedRun(run_id, &budget_controller);
        return execution;
    }

    fn runTextWithBoundSkills(
        self: *AbiSession,
        materializations: *skill_materialization.Manager,
        run_id: u64,
        prompt: []const u8,
        max_turns: u32,
    ) anyerror!SkillExecution {
        const preflight = try self.preflightRootRecords(&.{prompt});
        var budget_controller = session_budget.Controller.init(
            allocator,
            self.budget_state.profile,
            preflight,
        );
        errdefer self.reconcileBudgetedRunError(run_id, &budget_controller);
        var budget_provider = session_budget.BudgetedProvider{
            .allocator = allocator,
            .controller = &budget_controller,
            .base = self.core_session.provider.provider(),
        };
        if (self.active_budget_controller != null)
            return error.InvalidSessionState;
        self.active_budget_controller = &budget_controller;
        defer self.active_budget_controller = null;
        const binding: ?*SkillBinding = if (self.skill_binding) |*value| value else null;
        const has_model_skill = if (binding) |value|
            materializations.supportsExactFileModes() and
                model_skill_tool.Environment.hasModelInvocable(
                    value.snapshot(),
                    value.view(),
                )
        else
            false;
        var mcp_run_view = try self.materializeMcpRunView();
        defer if (mcp_run_view) |*run_view| run_view.deinit();
        const has_mcp = if (mcp_run_view) |*run_view| run_view.entries.len != 0 else false;
        const identity = core.agent_session.RunIdentity{
            .session_id = self.core_session.session_id,
            .run_id = run_id,
        };
        var mcp_environment: ?mcp_session.Environment = if (has_mcp)
            try mcp_session.Environment.init(
                allocator,
                &mcp_run_view.?,
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
                .mcp_view = if (has_mcp) &mcp_run_view.? else null,
                .budget_controller = &budget_controller,
                .permission_owner = self.permissionForkOwner(),
            });
        } else null;
        var skill_environment_live = skill_environment != null;
        defer if (skill_environment_live) skill_environment.?.deinit() catch {};

        var admitted = try self.core_session.admitRun(
            run_id,
            .{ .ctx = self, .emit = AbiSession.emit },
        );
        if (!self.startRunState(identity.session_id, run_id)) {
            _ = admitted.finishWithoutConversation() catch {};
            return error.CallbackFailed;
        }
        self.active_mcp_environment = if (mcp_environment) |*environment| environment else null;
        defer self.active_mcp_environment = null;
        const inner_surface = if (skill_environment) |*environment|
            environment.surface()
        else if (mcp_environment) |*environment|
            environment.surface()
        else
            core.agent_session.RunToolSurface{
                .definitions = self.core_session.tools.definitions,
                .dispatcher = self.core_session.tools.dispatcher(),
            };
        const execution_policy = if (skill_environment) |*environment|
            environment.executionPolicy()
        else if (mcp_environment) |*environment|
            environment.executionPolicy()
        else
            null;
        var budget_tools = session_budget.ToolEnvironment{
            .controller = &budget_controller,
            .base = inner_surface,
            .mcp_view = if (has_mcp) &mcp_run_view.? else null,
        };
        const result = admitted.runUserMessagesWithToolSurfaceUsingProvider(
            &.{prompt},
            max_turns,
            execution_policy,
            budget_tools.surface(),
            budget_provider.provider(),
        ) catch |run_error| {
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
        _ = try self.finishBudgetedRun(run_id, &budget_controller);
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
        return self.admitMaterializedSkillImpl(
            materializations,
            run_id,
            plan,
            parent_frame,
            null,
            null,
            null,
        );
    }

    fn admitMaterializedSkillBudgeted(
        self: *AbiSession,
        materializations: *skill_materialization.Manager,
        run_id: u64,
        plan: *const skill_activation.ActivationPlan,
        parent_frame: *policy_frame.PolicyFrame,
        budget_controller: *session_budget.Controller,
        budget_provider: *session_budget.BudgetedProvider,
        invocation_record: []const u8,
    ) anyerror!SkillAdmission {
        return self.admitMaterializedSkillImpl(
            materializations,
            run_id,
            plan,
            parent_frame,
            budget_controller,
            budget_provider,
            invocation_record,
        );
    }

    fn admitMaterializedSkillImpl(
        self: *AbiSession,
        materializations: *skill_materialization.Manager,
        run_id: u64,
        plan: *const skill_activation.ActivationPlan,
        parent_frame: *policy_frame.PolicyFrame,
        budget_controller: ?*session_budget.Controller,
        budget_provider: ?*session_budget.BudgetedProvider,
        invocation_record: ?[]const u8,
    ) anyerror!SkillAdmission {
        var mcp_run_view = try self.materializeMcpRunView();
        var keep_mcp_run_view = false;
        defer if (!keep_mcp_run_view) if (mcp_run_view) |*run_view| run_view.deinit();
        var admitted = try self.core_session.admitRun(
            run_id,
            .{ .ctx = self, .emit = AbiSession.emit },
        );
        if (!self.startRunState(self.core_session.session_id, run_id)) {
            _ = admitted.finishWithoutConversation() catch {};
            return error.CallbackFailed;
        }
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
        keep_mcp_run_view = true;
        return .{ .ready = .{
            .facade = self,
            .materializations = materializations,
            .admitted = admitted,
            .activation = activation,
            .budget_controller = budget_controller,
            .budget_provider = budget_provider,
            .invocation_record = invocation_record,
            .mcp_view = mcp_run_view,
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
    budget_controller: ?*session_budget.Controller,
    budget_provider: ?*session_budget.BudgetedProvider,
    /// Borrowed from the synchronous external run when budgeted. Test-only
    /// direct admission may omit it and falls back to local construction.
    invocation_record: ?[]const u8,
    /// Exact catalog generation retained for this admitted Run.
    mcp_view: ?mcp_session.View,

    fn executeInline(
        self: *MaterializedSkillRun,
        plan: *const skill_activation.ActivationPlan,
        max_turns: u32,
    ) anyerror!SkillExecution {
        var owned_invocation: ?[]u8 = null;
        defer if (owned_invocation) |record| allocator.free(record);
        const invocation_record = self.invocation_record orelse blk: {
            owned_invocation = canonicalInvocationRecord(
                allocator,
                plan,
            ) catch |record_error| {
                _ = try self.finishWithoutConversation();
                return record_error;
            };
            break :blk owned_invocation.?;
        };

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

        const budget_controller = self.budget_controller orelse {
            _ = try self.finishWithoutConversation();
            return error.InvalidSessionState;
        };
        const budget_provider = self.budget_provider orelse {
            _ = try self.finishWithoutConversation();
            return error.InvalidSessionState;
        };
        budget_controller.reconcileGeneratedRootPrompts(
            &.{ invocation_record, body_record },
        ) catch {
            _ = try self.finishWithoutConversation();
            return .{ .completed = .{
                .stop_reason = .api_error,
                .turns = 0,
                .tool_calls = 0,
            } };
        };

        const binding = if (self.facade.skill_binding) |*value| value else {
            _ = try self.finishWithoutConversation();
            return error.InvalidSessionState;
        };
        const has_mcp = if (self.mcp_view) |*run_view| run_view.entries.len != 0 else false;
        const root_mcp_restrictions = [_]mcp_session.SkillRestriction{.{
            .allowed = plan.skill.definition.allowed_tools,
            .disallowed = plan.skill.definition.disallowed_tools,
        }};
        var mcp_environment: ?mcp_session.Environment = if (has_mcp)
            mcp_session.Environment.initRestricted(
                allocator,
                &self.mcp_view.?,
                self.admitted.session.tools.definitions,
                self.admitted.session.tools.dispatcher(),
                null,
                &root_mcp_restrictions,
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
                    .mcp_view = if (has_mcp) &self.mcp_view.? else null,
                    .budget_controller = budget_controller,
                    .permission_owner = self.facade.permissionForkOwner(),
                }) catch |environment_error| {
                    _ = try self.finishWithoutConversation();
                    return environment_error;
                }
            else
                null;
        var environment_live = environment != null;
        defer if (environment_live) environment.?.deinit() catch {};
        self.facade.active_mcp_environment = if (mcp_environment) |*mcp_env| mcp_env else null;
        defer self.facade.active_mcp_environment = null;
        const inner_surface = if (environment) |*env|
            env.surface()
        else if (mcp_environment) |*mcp_env|
            mcp_env.surface()
        else
            core.agent_session.RunToolSurface{
                .definitions = self.admitted.session.tools.definitions,
                .dispatcher = self.admitted.session.tools.dispatcher(),
            };
        const execution_policy = if (environment) |*env|
            env.executionPolicy()
        else if (mcp_environment) |*mcp_env|
            mcp_env.executionPolicy()
        else
            self.activation.frame.executionPolicy();
        var budget_tools = session_budget.ToolEnvironment{
            .controller = budget_controller,
            .base = inner_surface,
            .mcp_view = if (has_mcp) &self.mcp_view.? else null,
        };
        const result = self.admitted.runUserMessagesWithToolSurfaceUsingProvider(
            &.{ invocation_record, body_record },
            max_turns,
            execution_policy,
            budget_tools.surface(),
            budget_provider.provider(),
        ) catch |run_error| {
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
        var owned_invocation: ?[]u8 = null;
        defer if (owned_invocation) |record| allocator.free(record);
        const invocation_record = self.invocation_record orelse blk: {
            owned_invocation = canonicalInvocationRecord(
                allocator,
                plan,
            ) catch |record_error| {
                _ = try self.finishWithoutConversation();
                return record_error;
            };
            break :blk owned_invocation.?;
        };

        if (self.admitted.abortSignal().isAborted()) {
            _ = try self.finishWithoutConversation();
            return .aborted;
        }

        const budget_controller = self.budget_controller orelse {
            _ = try self.finishWithoutConversation();
            return error.InvalidSessionState;
        };
        const budget_provider = self.budget_provider orelse {
            _ = try self.finishWithoutConversation();
            return error.InvalidSessionState;
        };
        budget_controller.reconcileGeneratedRootPrompts(
            &.{invocation_record},
        ) catch {
            _ = try self.finishWithoutConversation();
            return .{ .completed = .{
                .stop_reason = .api_error,
                .turns = 0,
                .tool_calls = 0,
            } };
        };

        var executor_context = ForkExecutorContext{
            .facade = self.facade,
            .session = self.admitted.session,
            .materializations = self.materializations,
            .activation = &self.activation,
            .plan = plan,
            .max_turns = max_turns,
            .budget_controller = budget_controller,
            .budget_provider = budget_provider,
            .mcp_view = if (self.mcp_view) |*run_view| run_view else null,
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
        var cleanup_failed = false;
        self.activation.deinit() catch {
            cleanup_failed = true;
        };
        if (self.mcp_view) |*run_view| {
            run_view.deinit();
            self.mcp_view = null;
        }
        if (cleanup_failed) return error.CoreError;
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
    budget_controller: *session_budget.Controller,
    budget_provider: *session_budget.BudgetedProvider,
    mcp_view: ?*const mcp_session.View,

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
        var permission_lease = child_permission.Lease{};
        permission_lease.init(self.facade.permissionForkOwner(), &projector);
        defer permission_lease.deinit();
        const host_run: ?core.agent_session.HostRunIdentity =
            if (self.session.host_identity_ctx) |host_ctx| .{
                .identity = identity,
                .host_session_ctx = host_ctx,
            } else null;
        const child_depth = try childDepth(self.activation.parent_agent_depth);
        const binding = if (self.facade.skill_binding) |*value| value else return error.InvalidSessionState;
        const has_mcp = if (self.mcp_view) |run_view| run_view.entries.len != 0 else false;
        const root_mcp_restrictions = [_]mcp_session.SkillRestriction{.{
            .allowed = self.plan.skill.definition.allowed_tools,
            .disallowed = self.plan.skill.definition.disallowed_tools,
        }};
        var mcp_environment: ?mcp_session.Environment = if (has_mcp)
            try mcp_session.Environment.initRestricted(
                output_allocator,
                self.mcp_view.?,
                self.session.tools.definitions,
                self.session.tools.dispatcher(),
                null,
                &root_mcp_restrictions,
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
                    .mcp_view = if (has_mcp) self.mcp_view else null,
                    .budget_controller = self.budget_controller,
                    .permission_owner = self.facade.permissionForkOwner(),
                })
            else
                null;
        var environment_live = environment != null;
        defer if (environment_live) environment.?.deinit() catch {};
        const inner_surface = if (environment) |*env|
            env.surface()
        else if (mcp_environment) |*mcp_env|
            mcp_env.surface()
        else
            core.agent_session.RunToolSurface{
                .definitions = self.session.tools.definitions,
                .dispatcher = self.session.tools.dispatcher(),
            };
        var budget_tools = session_budget.ToolEnvironment{
            .controller = self.budget_controller,
            .base = inner_surface,
            .mcp_view = if (has_mcp) self.mcp_view else null,
        };
        const child_surface = budget_tools.surface();
        const execution_policy = if (environment) |*env|
            env.executionPolicy()
        else if (mcp_environment) |*mcp_env|
            mcp_env.executionPolicy()
        else
            self.activation.frame.executionPolicy();

        self.facade.active_mcp_environment = if (mcp_environment) |*mcp_env| mcp_env else null;
        defer self.facade.active_mcp_environment = null;

        // 缺陷 A 修复:子 Agent 系统提示 = 静态字面量 + 环境段(cwd=workspace.root)。
        // 与 model_skill_tool.zig 共用 buildSubagentSystemPrompt,确保两路径一致。
        const sp_mod = core.system_prompt;
        const owned_subagent_system_prompt = sp_mod.buildSubagentSystemPrompt(
            output_allocator,
            self.session.model,
            self.session.workspace.root,
        ) catch null;
        defer if (owned_subagent_system_prompt) |prompt| output_allocator.free(prompt);
        const subagent_system_prompt = owned_subagent_system_prompt orelse
            sp_mod.SUBAGENT_LITERAL;

        const child = core.subagent.spawnAgentSink(
            output_allocator,
            self.budget_provider.provider(),
            self.session.provider.anthropicClient(),
            child_surface.definitions,
            permission_lease.permissionContext(),
            abort,
            self.activation.rendered_body,
            .{
                .max_turns = self.max_turns,
                .system_prompt = subagent_system_prompt,
                .session = identity.session_id,
                .agent_depth = child_depth,
                .tool_dispatcher = child_surface.dispatcher,
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
    output.writer.writeAll(&plan.skill.execution_id) catch return error.OutOfMemory;
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
fn completionFrom(handle: *wire.CompletionHandle) *completion_handles.Completion {
    return @ptrCast(@alignCast(handle));
}
fn completionHandle(value: *completion_handles.Completion) *wire.CompletionHandle {
    return @ptrCast(value);
}
fn completionStreamFrom(handle: *wire.CompletionStreamHandle) *completion_handles.Stream {
    return @ptrCast(@alignCast(handle));
}
fn completionStreamHandle(value: *completion_handles.Stream) *wire.CompletionStreamHandle {
    return @ptrCast(value);
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
        wire.STATUS_CHECKPOINT_BUDGET_REQUIRED => "checkpoint budget required",
        wire.STATUS_CHECKPOINT_CORRUPT => "checkpoint corrupt",
        wire.STATUS_CHECKPOINT_UNSUPPORTED => "checkpoint unsupported",
        wire.STATUS_CHECKPOINT_INCOMPATIBLE => "checkpoint incompatible",
        wire.STATUS_CHECKPOINT_IO => "checkpoint I/O failed",
        wire.STATUS_LOGICAL_SESSION_CONFLICT => "logical Session conflict",
        wire.STATUS_MCP_NOT_REFRESHED => "MCP catalog not refreshed",
        wire.STATUS_INVALID_MCP_SELECTION => "invalid MCP selection",
        wire.STATUS_COMPLETION_UNSUPPORTED_RESPONSE => "unsupported Completion response",
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
        error.WrongRuntime, error.WrongWorkspace, error.InvalidWorkspace, error.InvalidSource => wire.STATUS_INVALID_ARGUMENT,
        else => wire.STATUS_CORE_ERROR,
    };
}

fn catalogQueryStatus(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
        error.CatalogInvalid, error.InvalidScopeId => wire.STATUS_SKILL_CATALOG_INVALID,
        error.CatalogIncomplete => wire.STATUS_SKILL_CATALOG_INCOMPLETE,
        error.RuntimeBusy => wire.STATUS_BUSY,
        error.RuntimeUnavailable => wire.STATUS_INVALID_STATE,
        error.InvalidWorkspace, error.InvalidSource => wire.STATUS_INVALID_ARGUMENT,
        else => wire.STATUS_CORE_ERROR,
    };
}

fn completionStatus(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
        error.Busy => wire.STATUS_BUSY,
        error.TooLate => wire.STATUS_TOO_LATE,
        error.InvalidState => wire.STATUS_INVALID_STATE,
        error.UnsupportedResponse => wire.STATUS_COMPLETION_UNSUPPORTED_RESPONSE,
        else => wire.STATUS_CORE_ERROR,
    };
}

fn sessionMutationStatus(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
        error.CheckpointBudgetRequired => wire.STATUS_CHECKPOINT_BUDGET_REQUIRED,
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
        error.CheckpointBudgetRequired => wire.STATUS_CHECKPOINT_BUDGET_REQUIRED,
        error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
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
        error.NotRefreshed => wire.STATUS_MCP_NOT_REFRESHED,
        error.InvalidMcpBinding, error.InvalidSelection => wire.STATUS_INVALID_MCP_SELECTION,
        error.InvalidWorkspaceRoot,
        error.InvalidWorkspaceHome,
        error.InvalidBudget,
        error.InvalidProfile,
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
        error.CheckpointBudgetRequired => wire.STATUS_CHECKPOINT_BUDGET_REQUIRED,
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

fn providerCode(kind: core.types.ProviderKind) u32 {
    return switch (kind) {
        .anthropic => wire.PROVIDER_ANTHROPIC,
        .openai => wire.PROVIDER_OPENAI,
        .gemini => wire.PROVIDER_GEMINI,
    };
}

fn completionStopCode(reason: completion_handles.StopReason) u32 {
    return switch (reason) {
        .unknown => wire.COMPLETION_STOP_UNKNOWN,
        .end_turn => wire.COMPLETION_STOP_END_TURN,
        .max_tokens => wire.COMPLETION_STOP_MAX_TOKENS,
        .stop_sequence => wire.COMPLETION_STOP_STOP_SEQUENCE,
        .pause_turn => wire.COMPLETION_STOP_PAUSE_TURN,
        .refusal => wire.COMPLETION_STOP_REFUSAL,
        .aborted => wire.COMPLETION_STOP_ABORTED,
    };
}

fn completionAbortReason(code: u32) ?core.util_abort.Reason {
    return switch (code) {
        wire.ABORT_USER_REQUEST => .user_interrupt,
        wire.ABORT_TIMEOUT => .timeout,
        else => null,
    };
}

fn permissionMode(code: u32) ?core.types.PermissionMode {
    return switch (code) {
        wire.PERMISSION_DEFAULT => .default,
        wire.PERMISSION_ACCEPT_EDITS => .accept_edits,
        wire.PERMISSION_AUTO => .auto,
        wire.PERMISSION_DONT_ASK => .dont_ask,
        wire.PERMISSION_FULL_ACCESS => .bypass_permissions,
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

fn parseSkillPolicy(
    scratch: std.mem.Allocator,
    raw: *const wire.SkillPolicyV1,
    snapshot: *const skill_catalog.Snapshot,
) !skill_availability.Spec {
    if (raw.struct_size != @sizeOf(wire.SkillPolicyV1) or
        raw.reserved0 != 0 or
        !allZero(raw.reserved))
        return error.InvalidArgument;
    if (raw.granted_skill_id_count > wire.MAX_SKILL_CATALOG_SKILLS_V1)
        return error.ResourceLimit;
    const count = std.math.cast(usize, raw.granted_skill_id_count) orelse
        return error.Overflow;
    if (count == 0) {
        return .{ .default_state = .disabled, .exceptions = &.{} };
    }
    const ids = (raw.granted_skill_ids orelse return error.InvalidArgument)[0..count];
    const exceptions = try scratch.alloc(skill_availability.Exception, count);
    for (ids, 0..) |id, index| {
        if (id.len != 64) return error.InvalidArgument;
        const execution_id = try text(id);
        const record = snapshot.findByExecutionId(execution_id) orelse
            return error.ForeignSkillId;
        exceptions[index] = .{
            .skill_id = &record.skill_id,
            .state = .enabled,
        };
    }
    return .{
        .default_state = .disabled,
        .exceptions = exceptions,
    };
}

fn parseAdditionalSkillSources(
    scratch: std.mem.Allocator,
    ptr: ?[*]const wire.SkillSourceV1,
    count64: u64,
    metadata_total: *u64,
) ![]const skill_catalog_handles.AdditionalSource {
    if (count64 > wire.MAX_SKILL_SOURCES_V1) return error.ResourceLimit;
    const count = std.math.cast(usize, count64) orelse return error.Overflow;
    if (count == 0) return &.{};
    const raw_sources = (ptr orelse return error.InvalidArgument)[0..count];
    const sources = try scratch.alloc(skill_catalog_handles.AdditionalSource, count);
    for (raw_sources, sources) |raw, *source| {
        if (raw.struct_size != @sizeOf(wire.SkillSourceV1) or
            !allZero(raw.reserved)) return error.InvalidArgument;
        const scope: skill_catalog_handles.AuthorityScope = switch (raw.scope_code) {
            wire.SKILL_SOURCE_USER => .user,
            wire.SKILL_SOURCE_WORKSPACE => .workspace,
            else => return error.InvalidArgument,
        };
        try addMetadata(
            metadata_total,
            raw.root.len,
            wire.MAX_SESSION_METADATA_BYTES_V1,
        );
        try addMetadata(
            metadata_total,
            raw.source_instance_id.len,
            wire.MAX_SESSION_METADATA_BYTES_V1,
        );
        const root = try text(raw.root);
        const source_instance_id = try text(raw.source_instance_id);
        if (root.len == 0 or !skill_catalog_handles.validSourceInstanceId(source_instance_id))
            return error.InvalidArgument;
        const canonical = skill_catalog_handles.CanonicalWorkspace.init(
            scratch,
            root,
            root,
        ) catch |err| return if (err == error.OutOfMemory)
            error.OutOfMemory
        else
            error.InvalidArgument;
        source.* = .{
            .root = canonical.root,
            .scope = scope,
            .source_instance_id = source_instance_id,
        };
        // `scratch` is an Arena in every caller; the canonical strings remain
        // live through the synchronous query and are released with the Arena.
    }
    return sources;
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

fn parseMcpSelection(
    scratch: std.mem.Allocator,
    optional: ?*const wire.McpSelectionV1,
    metadata_total: *u64,
) ![]const mcp_session.Selector {
    const raw = optional orelse return &.{};
    if (raw.struct_size != @sizeOf(wire.McpSelectionV1) or
        raw.reserved0 != 0 or !allZero(raw.reserved))
        return error.InvalidArgument;
    if (raw.selector_count > wire.MAX_MCP_TOOLS_V1)
        return error.ResourceLimit;
    const count = std.math.cast(usize, raw.selector_count) orelse
        return error.Overflow;
    if (count == 0) return &.{};
    const descriptors = (raw.selectors orelse
        return error.InvalidArgument)[0..count];
    const selectors = try scratch.alloc(mcp_session.Selector, count);
    for (descriptors, selectors) |descriptor, *selector| {
        if (descriptor.struct_size != @sizeOf(wire.McpSelectorV1) or
            descriptor.reserved0 != 0 or !allZero(descriptor.reserved) or
            allZero(descriptor.server_binding_identity[0..]))
            return error.InvalidArgument;
        if (descriptor.tool_name.len == 0 or
            descriptor.tool_name.len > wire.MAX_MCP_TOOL_NAME_BYTES_V1)
            return error.ResourceLimit;
        try addMetadata(
            metadata_total,
            descriptor.tool_name.len,
            wire.MAX_SESSION_METADATA_BYTES_V1,
        );
        selector.* = .{
            .server_binding_identity = descriptor.server_binding_identity,
            .tool_name = try text(descriptor.tool_name),
        };
    }
    return selectors;
}

fn parseDurableBudget(
    optional: ?*const wire.DurableBudgetProfileV1,
) !session_budget.Profile {
    const raw = optional orelse return .{};
    if (raw.struct_size != @sizeOf(wire.DurableBudgetProfileV1) or
        raw.reserved0 != 0 or !allZero(raw.reserved))
        return error.InvalidArgument;
    const profile = session_budget.Profile{
        .hard_bytes = raw.hard_bytes,
        .soft_bytes = raw.soft_bytes,
        .input_cap_bytes = raw.input_cap_bytes,
        .provider_request_cap_bytes = raw.provider_request_cap_bytes,
        .provider_result_cap_bytes = raw.provider_result_cap_bytes,
        .tool_result_cap_bytes = raw.tool_result_cap_bytes,
        .mcp_result_cap_bytes = raw.mcp_result_cap_bytes,
        .audit_reserve_bytes = raw.audit_reserve_bytes,
        .terminal_reserve_bytes = raw.terminal_reserve_bytes,
    };
    try profile.validate();
    return profile;
}

fn parseCheckpointLimits(
    raw: *const wire.CheckpointLimitsV1,
) !session_checkpoint.Limits {
    if (raw.struct_size != @sizeOf(wire.CheckpointLimitsV1) or
        raw.reserved0 != 0 or raw.reserved1 != 0 or
        !allZero(raw.reserved))
        return error.InvalidArgument;
    if (raw.hard_bytes > wire.MAX_CHECKPOINT_BYTES_V1 or
        raw.chunk_bytes > wire.MAX_CHECKPOINT_CHUNK_BYTES_V1)
        return error.ResourceLimit;
    const limits = session_checkpoint.Limits{
        .hard_bytes = raw.hard_bytes,
        .chunk_bytes = raw.chunk_bytes,
        .max_section_bytes = raw.max_section_bytes,
        .max_string_bytes = raw.max_string_bytes,
        .max_messages = raw.max_messages,
        .max_blocks_per_message = raw.max_blocks_per_message,
    };
    try limits.validate();
    return limits;
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

fn mcpTransport(code: u32) ?mcp_negotiation.Transport {
    return switch (code) {
        wire.MCP_TRANSPORT_STDIO => .stdio,
        wire.MCP_TRANSPORT_STREAMABLE_HTTP => .streamable_http,
        else => null,
    };
}

fn mcpNegotiationPolicy(code: u32) ?mcp_negotiation.Policy {
    return switch (code) {
        wire.MCP_NEGOTIATION_AUTO => .auto,
        wire.MCP_NEGOTIATION_MODERN_ONLY => .modern_only,
        wire.MCP_NEGOTIATION_LEGACY_ONLY => .legacy_only,
        wire.MCP_NEGOTIATION_LEGACY_2025_06_ONLY => .legacy_2025_06_only,
        else => null,
    };
}

fn parseMcpProtocolLimits(
    optional: ?*const wire.McpProtocolLimitsV1,
) !mcp_canonical.Limits {
    const raw = optional orelse return .{};
    if (raw.struct_size != @sizeOf(wire.McpProtocolLimitsV1) or
        raw.reserved0 != 0 or !allZero(raw.reserved))
        return error.InvalidArgument;
    const result = mcp_canonical.Limits{
        .max_frame_bytes = std.math.cast(usize, raw.max_frame_bytes) orelse
            return error.Overflow,
        .max_tools = std.math.cast(usize, raw.max_tools) orelse
            return error.Overflow,
        .max_tool_name_bytes = std.math.cast(usize, raw.max_tool_name_bytes) orelse
            return error.Overflow,
        .max_text_bytes = std.math.cast(usize, raw.max_text_bytes) orelse
            return error.Overflow,
        .max_schema_bytes = std.math.cast(usize, raw.max_schema_bytes) orelse
            return error.Overflow,
        .max_json_depth = std.math.cast(u16, raw.max_json_depth) orelse
            return error.Overflow,
        .max_json_nodes = std.math.cast(u32, raw.max_json_nodes) orelse
            return error.Overflow,
        .max_cursor_bytes = std.math.cast(usize, raw.max_cursor_bytes) orelse
            return error.Overflow,
        .max_versions = std.math.cast(usize, raw.max_versions) orelse
            return error.Overflow,
    };
    try result.validate();
    if (raw.max_frame_bytes > wire.MAX_MCP_FRAME_BYTES_V1 or
        raw.max_tools > wire.MAX_MCP_TOOLS_V1 or
        raw.max_tool_name_bytes > wire.MAX_MCP_TOOL_NAME_BYTES_V1 or
        raw.max_text_bytes > wire.MAX_MCP_TEXT_BYTES_V1 or
        raw.max_schema_bytes > wire.MAX_MCP_SCHEMA_BYTES_V1 or
        raw.max_cursor_bytes > wire.MAX_MCP_CURSOR_BYTES_V1 or
        raw.max_versions > wire.MAX_MCP_PROTOCOL_VERSIONS_V1)
        return error.ResourceLimit;
    return result;
}

fn parseMcpCatalogLimits(
    optional: ?*const wire.McpCatalogLimitsV1,
) !mcp_catalog.Limits {
    const raw = optional orelse return .{};
    if (raw.struct_size != @sizeOf(wire.McpCatalogLimitsV1) or
        raw.reserved0 != 0 or !allZero(raw.reserved))
        return error.InvalidArgument;
    if (raw.max_servers == 0 or raw.max_servers > wire.MAX_MCP_SERVERS_V1 or
        raw.max_namespace_bytes == 0 or
        raw.max_namespace_bytes > wire.MAX_MCP_NAMESPACE_BYTES_V1 or
        raw.max_issues == 0 or raw.max_issues > wire.MAX_MCP_CATALOG_ISSUES_V1)
        return error.ResourceLimit;
    return .{
        .max_servers = std.math.cast(usize, raw.max_servers) orelse
            return error.Overflow,
        .max_namespace_bytes = std.math.cast(usize, raw.max_namespace_bytes) orelse
            return error.Overflow,
        .max_issues = std.math.cast(usize, raw.max_issues) orelse
            return error.Overflow,
    };
}

const ParsedMcpSpecs = struct {
    connectors: []*AbiMcpConnector,
    specs: []mcp_catalog.ServerSpec,

    fn deinit(self: ParsedMcpSpecs) void {
        for (self.connectors) |connector| connector.connector().release();
    }
};

fn parseMcpSpecs(
    scratch: std.mem.Allocator,
    descriptors_ptr: ?[*]const wire.McpServerV1,
    descriptor_count: u64,
    limits: mcp_catalog.Limits,
    metadata_bytes: *u64,
) !ParsedMcpSpecs {
    if (descriptor_count > wire.MAX_MCP_SERVERS_V1 or
        descriptor_count > limits.max_servers)
        return error.ResourceLimit;
    const count = std.math.cast(usize, descriptor_count) orelse
        return error.Overflow;
    const descriptors = if (count == 0) &.{} else (descriptors_ptr orelse
        return error.InvalidArgument)[0..count];
    const connectors = try scratch.alloc(*AbiMcpConnector, count);
    var initialized: usize = 0;
    errdefer for (connectors[0..initialized]) |connector|
        connector.connector().release();
    const specs = try scratch.alloc(mcp_catalog.ServerSpec, count);
    for (descriptors, connectors, specs) |descriptor, *connector_slot, *spec| {
        if (descriptor.struct_size != @sizeOf(wire.McpServerV1) or
            descriptor.reserved0 != 0 or descriptor.reserved1 != 0 or
            descriptor.connector.struct_size != @sizeOf(wire.McpConnectorV1) or
            descriptor.connector.reserved0 != 0 or
            !allZero(descriptor.connector.reserved) or
            descriptor.connector.open == null or
            descriptor.connector.request == null or
            descriptor.connector.notify == null or
            descriptor.connector.close == null or
            descriptor.connector.release_response == null or
            descriptor.connector.retain_connector == null or
            descriptor.connector.release_connector == null or
            allZero(descriptor.configuration_fingerprint))
            return error.InvalidArgument;
        const transport = mcpTransport(descriptor.transport_code) orelse
            return error.InvalidArgument;
        const policy = mcpNegotiationPolicy(descriptor.negotiation_policy_code) orelse
            return error.InvalidArgument;
        if (descriptor.timeout_ms == 0) return error.InvalidArgument;
        for ([_]wire.BytesViewV1{
            descriptor.namespace,
            descriptor.client_name,
            descriptor.client_version,
        }) |value| try addMetadata(
            metadata_bytes,
            value.len,
            wire.MAX_RUNTIME_METADATA_BYTES_V1,
        );
        const namespace = try text(descriptor.namespace);
        const client_name = try text(descriptor.client_name);
        const client_version = try text(descriptor.client_version);
        if (client_name.len == 0 or client_version.len == 0)
            return error.InvalidArgument;
        const protocol_limits = try parseMcpProtocolLimits(descriptor.protocol_limits);
        const connector = try AbiMcpConnector.create(
            descriptor.connector,
            transport,
            protocol_limits.max_frame_bytes,
            descriptor.timeout_ms,
        );
        connector_slot.* = connector;
        initialized += 1;
        spec.* = .{
            .binding = descriptor.server_binding_identity,
            .namespace = namespace,
            .configuration_fingerprint = descriptor.configuration_fingerprint,
            .connector = connector.connector(),
            .transport = transport,
            .policy = policy,
            .client = .{ .name = client_name, .version = client_version },
            .timeout_ms = descriptor.timeout_ms,
            .protocol_limits = protocol_limits,
        };
    }
    return .{ .connectors = connectors, .specs = specs };
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
    const mcp_limits = parseMcpCatalogLimits(config.mcp_catalog_limits) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    const parsed_mcp = parseMcpSpecs(
        a,
        config.mcp_servers,
        config.mcp_server_count,
        mcp_limits,
        &runtime_metadata,
    ) catch |err| return failError(inputErrorStatus(err), err, out_error);
    defer parsed_mcp.deinit();

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
    self.mcp_manager = mcp_catalog.Manager.init(
        allocator,
        parsed_mcp.specs,
        mcp_limits,
    ) catch |err| return failError(inputErrorStatus(err), err, out_error);
    var keep_mcp_manager = false;
    defer if (!keep_mcp_manager) {
        self.mcp_manager.?.deinit();
        self.mcp_manager = null;
    };
    self.core_runtime = core.agent_session.AgentRuntime.create(allocator, .{ .builtin_tools = builtin_names, .host_sync_tools = native_tools }) catch |err| {
        return failError(runtimeErrorStatus(err), err, out_error);
    };
    out.* = self.handle();
    keep_host_tools = true;
    keep_mcp_manager = true;
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
        query.reserved0 != 0 or
        !allZero(query.reserved))
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

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const additional_sources = parseAdditionalSkillSources(
        scratch.allocator(),
        query.additional_sources,
        query.additional_source_count,
        &metadata,
    ) catch |err| return failError(inputErrorStatus(err), err, out_error);

    var workspace = skill_catalog_handles.CanonicalWorkspace.init(
        allocator,
        root,
        home,
    ) catch |err| return failError(catalogLifecycleStatus(err), err, out_error);
    defer workspace.deinit();
    const host = runtime.catalogs.queryWorkspace(
        runtime.materializations.io,
        &workspace,
        epoch,
        additional_sources,
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

fn parseCompletionRequest(
    scratch: std.mem.Allocator,
    request_ptr: ?*const wire.CompletionRequestV1,
) !completion_handles.Request {
    const request = request_ptr orelse return error.InvalidArgument;
    if (request.struct_size != @sizeOf(wire.CompletionRequestV1) or
        request.reserved0 != 0 or !allZero(request.reserved))
        return error.InvalidArgument;
    if (request.message_count == 0)
        return error.InvalidArgument;
    if (request.message_count > wire.MAX_COMPLETION_MESSAGES_V1)
        return error.ResourceLimit;
    const count = std.math.cast(usize, request.message_count) orelse
        return error.Overflow;
    const source = (request.messages orelse return error.InvalidArgument)[0..count];
    const messages = try scratch.alloc(completion_handles.TextMessage, count);
    var total_bytes: u64 = 0;
    for (source, messages) |input, *output| {
        if (input.struct_size != @sizeOf(wire.CompletionMessageV1) or
            !allZero(input.reserved))
            return error.InvalidArgument;
        const role: core.types.MessageRole = switch (input.role_code) {
            wire.COMPLETION_ROLE_USER => .user,
            wire.COMPLETION_ROLE_ASSISTANT => .assistant,
            else => return error.InvalidArgument,
        };
        const message_text = try text(input.text);
        total_bytes = std.math.add(u64, total_bytes, input.text.len) catch
            return error.ResourceLimit;
        if (total_bytes > wire.MAX_COMPLETION_REQUEST_BYTES_V1)
            return error.ResourceLimit;
        output.* = .{ .role = role, .text = message_text };
    }
    const system_text = try text(request.system);
    total_bytes = std.math.add(u64, total_bytes, request.system.len) catch
        return error.ResourceLimit;
    if (total_bytes > wire.MAX_COMPLETION_REQUEST_BYTES_V1)
        return error.ResourceLimit;
    return .{
        .messages = messages,
        .system = if (system_text.len == 0) null else system_text,
    };
}

fn completionCreate(
    config_ptr: ?*const wire.CompletionConfigV1,
    out_completion: ?*?*wire.CompletionHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_completion) |out| out.* = null;
    emptyError(out_error);
    const config = config_ptr orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "CompletionConfigV1 is required", out_error);
    const output = out_completion orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_completion is required", out_error);
    if (config.struct_size != @sizeOf(wire.CompletionConfigV1) or
        !allZero(config.reserved))
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid CompletionConfigV1", out_error);
    const provider_kind = provider(config.provider_kind_code) orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid Completion provider", out_error);
    var total_bytes: u64 = 0;
    for ([_]wire.BytesViewV1{ config.api_key, config.base_url, config.model }) |value| {
        addMetadata(&total_bytes, value.len, wire.MAX_COMPLETION_CONFIG_BYTES_V1) catch |err|
            return failError(inputErrorStatus(err), err, out_error);
    }
    const api_key = text(config.api_key) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    const base_url = text(config.base_url) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    const model = text(config.model) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    if (api_key.len == 0 or model.len == 0)
        return fail(wire.STATUS_INVALID_ARGUMENT, "Completion api_key and model are required", out_error);
    const completion = completion_handles.Completion.create(
        allocator,
        provider_kind,
        api_key,
        model,
        if (base_url.len == 0) null else base_url,
    ) catch |err| return failError(completionStatus(err), err, out_error);
    output.* = completionHandle(completion);
    return wire.STATUS_OK;
}

fn completionDestroy(
    handle: ?*wire.CompletionHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    emptyError(out_error);
    const completion = completionFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "Completion is required", out_error));
    completion.destroy() catch |err|
        return failError(completionStatus(err), err, out_error);
    return wire.STATUS_OK;
}

fn completionDescribe(
    handle: ?*wire.CompletionHandle,
    out_info: ?*wire.CompletionInfoV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_info) |out| out.* = std.mem.zeroes(wire.CompletionInfoV1);
    emptyError(out_error);
    const completion = completionFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "Completion is required", out_error));
    const output = out_info orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_info is required", out_error);
    const model = allocator.dupe(u8, completion.configuredModel()) catch
        return fail(wire.STATUS_OUT_OF_MEMORY, "allocating Completion model failed", out_error);
    output.* = .{
        .struct_size = @sizeOf(wire.CompletionInfoV1),
        .provider_kind_code = providerCode(completion.providerKind()),
        .model = .{ .ptr = model.ptr, .len = model.len },
        .reserved = [_]u64{0} ** 3,
    };
    return wire.STATUS_OK;
}

fn completionComplete(
    handle: ?*wire.CompletionHandle,
    request_ptr: ?*const wire.CompletionRequestV1,
    out_result: ?*wire.CompletionResultV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_result) |out| out.* = std.mem.zeroes(wire.CompletionResultV1);
    emptyError(out_error);
    const completion = completionFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "Completion is required", out_error));
    const output = out_result orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_result is required", out_error);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const request = parseCompletionRequest(scratch.allocator(), request_ptr) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    const result = completion.complete(request) catch |err|
        return failError(completionStatus(err), err, out_error);
    output.* = .{
        .struct_size = @sizeOf(wire.CompletionResultV1),
        .stop_reason_code = completionStopCode(result.stop_reason),
        .text = .{
            .ptr = if (result.text.len == 0) null else result.text.ptr,
            .len = result.text.len,
        },
        .input_tokens = result.usage.input_tokens,
        .output_tokens = result.usage.output_tokens,
        .cache_read_input_tokens = result.usage.cache_read_input_tokens,
        .cache_creation_input_tokens = result.usage.cache_creation_input_tokens,
        .reserved = [_]u64{0} ** 2,
    };
    return wire.STATUS_OK;
}

fn completionStreamStart(
    handle: ?*wire.CompletionHandle,
    request_ptr: ?*const wire.CompletionRequestV1,
    out_stream: ?*?*wire.CompletionStreamHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_stream) |out| out.* = null;
    emptyError(out_error);
    const completion = completionFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "Completion is required", out_error));
    const output = out_stream orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_stream is required", out_error);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const request = parseCompletionRequest(scratch.allocator(), request_ptr) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    const stream = completion.startStream(request) catch |err|
        return failError(completionStatus(err), err, out_error);
    output.* = completionStreamHandle(stream);
    return wire.STATUS_OK;
}

fn completionStreamNext(
    handle: ?*wire.CompletionStreamHandle,
    out_event: ?*wire.CompletionEventV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_event) |out| out.* = std.mem.zeroes(wire.CompletionEventV1);
    emptyError(out_error);
    const stream = completionStreamFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "Completion stream is required", out_error));
    const output = out_event orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_event is required", out_error);
    const event = stream.next() catch |err|
        return failError(completionStatus(err), err, out_error);
    output.* = .{
        .struct_size = @sizeOf(wire.CompletionEventV1),
        .kind_code = switch (event) {
            .text => wire.COMPLETION_EVENT_TEXT,
            .thinking => wire.COMPLETION_EVENT_THINKING,
            .usage => wire.COMPLETION_EVENT_USAGE,
            .done => wire.COMPLETION_EVENT_DONE,
        },
        .payload = switch (event) {
            .text, .thinking => |payload| .{
                .ptr = if (payload.len == 0) null else payload.ptr,
                .len = payload.len,
            },
            .usage, .done => .{ .ptr = null, .len = 0 },
        },
        .input_tokens = switch (event) {
            .usage => |usage| usage.input_tokens,
            else => 0,
        },
        .output_tokens = switch (event) {
            .usage => |usage| usage.output_tokens,
            else => 0,
        },
        .cache_read_input_tokens = switch (event) {
            .usage => |usage| usage.cache_read_input_tokens,
            else => 0,
        },
        .cache_creation_input_tokens = switch (event) {
            .usage => |usage| usage.cache_creation_input_tokens,
            else => 0,
        },
        .stop_reason_code = switch (event) {
            .done => |reason| completionStopCode(reason),
            else => wire.COMPLETION_STOP_UNKNOWN,
        },
        .reserved0 = 0,
        .reserved = [_]u64{0} ** 2,
    };
    return wire.STATUS_OK;
}

fn completionStreamAbort(
    handle: ?*wire.CompletionStreamHandle,
    reason_code: u32,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    emptyError(out_error);
    const stream = completionStreamFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "Completion stream is required", out_error));
    const reason = completionAbortReason(reason_code) orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid Completion abort reason", out_error);
    stream.abort(reason) catch |err|
        return failError(completionStatus(err), err, out_error);
    return wire.STATUS_OK;
}

fn completionStreamDestroy(
    handle: ?*wire.CompletionStreamHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    emptyError(out_error);
    const stream = completionStreamFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "Completion stream is required", out_error));
    stream.destroy();
    return wire.STATUS_OK;
}

const McpCatalogServerJson = struct {
    server_binding_identity: []const u8,
    namespace: []const u8,
    negotiated_protocol: []const u8,
    server_fingerprint: []const u8,
    cache_scope: []const u8,
    fresh: bool,
    ttl_remaining_ms: u64,
    tool_offset: u32,
    tool_count: u32,
};

const McpCatalogToolJson = struct {
    server_binding_identity: []const u8,
    canonical_name: []const u8,
    schema_fingerprint: []const u8,
    permission_binding: []const u8,
};

const McpCatalogIssueJson = struct {
    issue_id: []const u8,
    server_binding_identity: []const u8,
    tool_name: ?[]const u8,
    kind: []const u8,
    detail: []const u8,
};

const McpCatalogDescriptionJson = struct {
    schema: []const u8 = "agentcore.mcp-catalog/v1",
    catalog_generation: u64,
    desired_revision: u64,
    active_revision: u64,
    convergence: []const u8,
    catalog_fingerprint: []const u8,
    servers: []const McpCatalogServerJson,
    tools: []const McpCatalogToolJson,
    issues: []const McpCatalogIssueJson,
};

fn lowerHexAlloc(
    output_allocator: std.mem.Allocator,
    bytes: []const u8,
) error{OutOfMemory}![]u8 {
    const result = output_allocator.alloc(u8, bytes.len * 2) catch
        return error.OutOfMemory;
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        result[index * 2] = alphabet[byte >> 4];
        result[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return result;
}

fn encodeMcpCatalogDescription(
    output_allocator: std.mem.Allocator,
    description: *const mcp_catalog.Description,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(output_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const servers = try a.alloc(McpCatalogServerJson, description.servers.len);
    for (description.servers, servers) |server, *dto| dto.* = .{
        .server_binding_identity = try lowerHexAlloc(a, &server.server_binding_identity),
        .namespace = server.namespace,
        .negotiated_protocol = server.era.version(),
        .server_fingerprint = try lowerHexAlloc(a, &server.server_fingerprint),
        .cache_scope = @tagName(server.cache_scope),
        .fresh = server.fresh,
        .ttl_remaining_ms = server.ttl_remaining_ms,
        .tool_offset = server.tool_offset,
        .tool_count = server.tool_count,
    };
    const tools = try a.alloc(McpCatalogToolJson, description.tools.len);
    for (description.tools, tools) |tool, *dto| dto.* = .{
        .server_binding_identity = try lowerHexAlloc(a, &tool.server_binding_identity),
        .canonical_name = tool.canonical_name,
        .schema_fingerprint = try lowerHexAlloc(a, &tool.schema_fingerprint),
        .permission_binding = try lowerHexAlloc(a, &tool.permission_binding),
    };
    const issues = try a.alloc(McpCatalogIssueJson, description.issues.len);
    for (description.issues, issues) |issue, *dto| dto.* = .{
        .issue_id = try lowerHexAlloc(a, &issue.issue_id),
        .server_binding_identity = try lowerHexAlloc(a, &issue.server_binding_identity),
        .tool_name = issue.tool_name,
        .kind = issue.kind,
        .detail = issue.detail,
    };
    const dto = McpCatalogDescriptionJson{
        .catalog_generation = description.generation,
        .desired_revision = description.desired_revision,
        .active_revision = description.active_revision,
        .convergence = @tagName(description.convergence),
        .catalog_fingerprint = try lowerHexAlloc(a, &description.fingerprint),
        .servers = servers,
        .tools = tools,
        .issues = issues,
    };
    const encoded = std.json.Stringify.valueAlloc(output_allocator, dto, .{}) catch
        return error.OutOfMemory;
    if (encoded.len > wire.MAX_DESCRIPTION_JSON_BYTES_V1) {
        output_allocator.free(encoded);
        return error.ResourceLimit;
    }
    return encoded;
}

fn runtimeRefreshMcp(
    runtime_handle: ?*wire.RuntimeHandle,
    out_generation: ?*u64,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_generation) |out| out.* = 0;
    emptyError(out_error);
    const runtime = runtimeFrom(runtime_handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "runtime is required", out_error));
    const out = out_generation orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_catalog_generation is required", out_error);
    var runtime_call = runtime.catalogs.enterCall() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    defer runtime_call.deinit();
    const manager = if (runtime.mcp_manager) |*value| value else return fail(wire.STATUS_INVALID_STATE, "Runtime has no MCP manager", out_error);
    out.* = manager.refresh() catch |err| return failError(switch (err) {
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
        error.InvalidConfig => wire.STATUS_INVALID_ARGUMENT,
        error.ReentrantControlCall => wire.STATUS_INVALID_STATE,
        else => wire.STATUS_CORE_ERROR,
    }, err, out_error);
    return wire.STATUS_OK;
}

fn runtimeApplyMcpConfiguration(
    runtime_handle: ?*wire.RuntimeHandle,
    configuration_ptr: ?*const wire.McpConfigurationV1,
    out_report: ?*wire.McpApplyReportV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_report) |out| out.* = std.mem.zeroes(wire.McpApplyReportV1);
    emptyError(out_error);
    const runtime = runtimeFrom(runtime_handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "runtime is required", out_error));
    const configuration = configuration_ptr orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "MCP configuration is required", out_error);
    const out = out_report orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_apply_report is required", out_error);
    if (configuration.struct_size != @sizeOf(wire.McpConfigurationV1) or
        configuration.reserved0 != 0 or !allZero(configuration.reserved) or
        configuration.desired_revision == 0)
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid McpConfigurationV1", out_error);
    var runtime_call = runtime.catalogs.enterCall() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    defer runtime_call.deinit();
    const manager = if (runtime.mcp_manager) |*value| value else return fail(wire.STATUS_INVALID_STATE, "Runtime has no MCP manager", out_error);

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var metadata_bytes: u64 = 0;
    const parsed = parseMcpSpecs(
        scratch.allocator(),
        configuration.servers,
        configuration.server_count,
        manager.limits,
        &metadata_bytes,
    ) catch |err| return failError(inputErrorStatus(err), err, out_error);
    defer parsed.deinit();
    const report = manager.apply(
        configuration.desired_revision,
        parsed.specs,
    ) catch |err| return failError(switch (err) {
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
        error.InvalidConfig => wire.STATUS_INVALID_ARGUMENT,
        error.NotRefreshed => wire.STATUS_MCP_NOT_REFRESHED,
        error.ReentrantControlCall => wire.STATUS_INVALID_STATE,
    }, err, out_error);
    out.* = .{
        .struct_size = @sizeOf(wire.McpApplyReportV1),
        .disposition_code = switch (report.disposition) {
            .applied => wire.MCP_APPLY_APPLIED,
            .superseded => wire.MCP_APPLY_SUPERSEDED,
            .rejected => wire.MCP_APPLY_REJECTED,
        },
        .desired_revision = report.desired_revision,
        .active_revision = report.active_revision,
        .catalog_generation = report.catalog_generation,
        .reserved = [_]u64{0} ** 4,
    };
    return wire.STATUS_OK;
}

fn runtimeDescribeMcp(
    runtime_handle: ?*wire.RuntimeHandle,
    out_description: ?*wire.OwnedBytesV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_description) |out| out.* = .{ .ptr = null, .len = 0 };
    emptyError(out_error);
    const runtime = runtimeFrom(runtime_handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "runtime is required", out_error));
    const out = out_description orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_description_json is required", out_error);
    var runtime_call = runtime.catalogs.enterCall() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    defer runtime_call.deinit();
    const manager = if (runtime.mcp_manager) |*value| value else return fail(wire.STATUS_INVALID_STATE, "Runtime has no MCP manager", out_error);
    var description = manager.describeCurrent(allocator) catch |err|
        return failError(switch (err) {
            error.NotRefreshed => wire.STATUS_MCP_NOT_REFRESHED,
            error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
            error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
            else => wire.STATUS_CORE_ERROR,
        }, err, out_error);
    defer description.deinit();
    const encoded = encodeMcpCatalogDescription(allocator, &description) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    out.* = .{ .ptr = encoded.ptr, .len = encoded.len };
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
    mcp_selection_transfer: ?*?mcp_session.Selection = null,
    mcp_invalidated_without_view: u32 = 0,
    authority_issue_seeds: []const session_authority.AuthorityIssueSeed = &.{},
    budget_profile: session_budget.Profile = .{},
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
    mcp_selectors: []const mcp_session.Selector = &.{},
    workspace_scope_id: [64]u8,
    budget_profile: session_budget.Profile = .{},
};

const InternalRestoreResult = struct {
    session: *AbiSession,
    report: session_authority.RestoreReport,
};

const AbiCheckpointSink = struct {
    descriptor: wire.CheckpointSinkV1,

    fn interface(self: *AbiCheckpointSink) session_checkpoint.Sink {
        return .{ .ctx = self, .write_fn = write };
    }

    fn write(raw: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *AbiCheckpointSink = @ptrCast(@alignCast(raw));
        const status = self.descriptor.write.?(self.descriptor.ctx, view(bytes));
        if (status != wire.CHECKPOINT_IO_OK) return error.HostSinkFailed;
    }
};

const AbiCheckpointSource = struct {
    descriptor: wire.CheckpointSourceV1,

    fn interface(self: *AbiCheckpointSource) session_checkpoint.Source {
        return .{ .ctx = self, .read_fn = read };
    }

    fn read(raw: *anyopaque, destination: []u8) anyerror!usize {
        const self: *AbiCheckpointSource = @ptrCast(@alignCast(raw));
        var read_len: u64 = 0;
        const status = self.descriptor.read.?(
            self.descriptor.ctx,
            if (destination.len == 0) null else destination.ptr,
            destination.len,
            &read_len,
        );
        if (status != wire.CHECKPOINT_IO_OK or read_len > destination.len)
            return error.HostSourceFailed;
        return @intCast(read_len);
    }
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
    var budget_state = try session_budget.SessionState.init(
        config.budget_profile,
    );
    if (config.restored) |decoded|
        try budget_state.updateUsage(decoded.descriptor.total_bytes);
    var initial_mcp_selection = if (config.mcp_selection_transfer) |source| blk: {
        const transferred = source.*;
        source.* = null;
        break :blk transferred;
    } else try createInitialMcpSelection(
        runtime,
        config.mcp_selectors,
        config.mcp_build_mode,
    );
    var keep_mcp_selection = false;
    defer if (!keep_mcp_selection) if (initial_mcp_selection) |*selection| selection.deinit();
    const mcp_tool_count = if (initial_mcp_selection) |*selection| selection.entries.len else 0;
    const authority_tool_names = try allocator.alloc(
        []const u8,
        config.allowed_tools.len + mcp_tool_count,
    );
    defer allocator.free(authority_tool_names);
    @memcpy(authority_tool_names[0..config.allowed_tools.len], config.allowed_tools);
    if (initial_mcp_selection) |*selection| {
        for (selection.entries, authority_tool_names[config.allowed_tools.len..]) |entry, *name|
            name.* = entry.model_name;
    }
    const mcp_invalidated = std.math.add(
        u32,
        config.mcp_invalidated_without_view,
        if (initial_mcp_selection) |*selection| selection.invalidated else 0,
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
    var authority_issues = try session_authority.IssueLedger.init(
        allocator,
        config.authority_issue_seeds,
    );
    var keep_authority_issues = false;
    defer if (!keep_authority_issues) authority_issues.deinit();
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
        .mcp_selection = initial_mcp_selection,
        .checkpoint_generation = if (config.restored) |decoded|
            decoded.descriptor.checkpoint_generation
        else
            0,
        .policy_generation = policy_generation,
        .policy_fingerprint = policy_fingerprint,
        .catalog_generation = if (initial_mcp_selection) |*selection|
            selection.catalog_generation
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
        .authority_issues = authority_issues,
        .permission_state = permission_state,
        .permission_audit = permission_audit,
        .run_state_projector = run_state.Projector.init(allocator),
        .budget_state = budget_state,
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
    keep_authority_issues = true;
    keep_mcp_selection = true;
    errdefer {
        if (self.mcp_selection) |*selection| selection.deinit();
        if (self.permission_audit) |*audit| audit.deinit();
        if (self.authority_issues) |*issues| issues.deinit();
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
    self.lifecycle_session = self.core_session;
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
    errdefer if (self.policy_root) |root| root.release();
    const initial_usage = try self.measureDurableUsage();
    try self.budget_state.updateUsage(initial_usage.total_bytes);
    // Session materialization proves that the restored state is encodable.
    // Capacity for a future Run is a separate admission question; requiring a
    // full Run reserve here would make a valid near-full checkpoint impossible
    // to restore and therefore impossible to compact or inspect.
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
    var restored_mcp_selection: ?mcp_session.Selection = null;
    defer if (restored_mcp_selection) |*selection| selection.deinit();
    var mcp_invalidated_without_view: u32 = 0;
    if (restored_mcp_state) |*state| {
        const historical_selectors = try state.selectors(allocator);
        defer allocator.free(historical_selectors);
        var bounded_selectors: std.ArrayList(mcp_session.Selector) = .empty;
        defer bounded_selectors.deinit(allocator);
        for (historical_selectors) |historical| {
            var allowed = false;
            for (config.mcp_selectors) |current| {
                if (std.mem.eql(
                    u8,
                    &historical.server_binding_identity,
                    &current.server_binding_identity,
                ) and std.mem.eql(u8, historical.tool_name, current.tool_name)) {
                    allowed = true;
                    break;
                }
            }
            if (allowed) {
                try bounded_selectors.append(allocator, historical);
            } else {
                mcp_invalidated_without_view +|= 1;
            }
        }
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
                    bounded_selectors.items,
                    .restore_degraded,
                );
            } else {
                mcp_invalidated_without_view = @intCast(state.entries.len);
            }
        } else {
            mcp_invalidated_without_view = @intCast(state.entries.len);
        }
    }
    if (restored_mcp_view) |*restored_view| {
        restored_mcp_selection = try mcp_session.Selection.fromView(
            allocator,
            restored_view,
        );
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
    var authority_issue_seeds: std.ArrayList(
        session_authority.AuthorityIssueSeed,
    ) = .empty;
    defer authority_issue_seeds.deinit(allocator);
    if (restored_skill) |*skill_state| {
        for (skill_state.entries) |entry| {
            if (entry.state != .enabled) continue;
            var still_enabled = false;
            if (binding) |*current| {
                for (current.snapshot().skills, 0..) |record, index| {
                    // Checkpoint SkillEntry.skill_id stores the execution identity.
                    if (std.mem.eql(u8, &record.execution_id, &entry.skill_id)) {
                        still_enabled = current.selection.states[index] == .enabled;
                        break;
                    }
                }
            }
            if (still_enabled) continue;
            try authority_issue_seeds.append(allocator, .{
                .subsystem = .skill,
                .reason = switch (skill_summary.disposition) {
                    .changed => .identity_changed,
                    .narrowed => .authority_narrowed,
                    .unavailable, .not_bound, .restored => .unavailable,
                },
                .skill_id = entry.skill_id,
            });
        }
    }
    for (restored_permission.rules) |rule| {
        const resolvable = if (!permission_reconciliation.fingerprint_compatible)
            false
        else if (rule.tool.namespace == .builtin)
            session_permission.isKnownBuiltin(rule.tool.name) and
                containsName(config.allowed_tools, rule.tool.name)
        else
            resolver.interface().isResolvable(rule.tool);
        if (resolvable) continue;
        try authority_issue_seeds.append(allocator, .{
            .subsystem = .permission,
            .reason = if (permission_reconciliation.fingerprint_compatible)
                .unavailable
            else
                .policy_changed,
            .permission_rule_id = rule.rule_id,
            .authority_binding = rule.tool.binding,
            .canonical_name = rule.tool.name,
        });
    }
    if (restored_mcp_state) |*mcp_state| {
        for (mcp_state.entries) |entry| {
            const restored_entry = if (restored_mcp_view) |*mcp_bound|
                mcp_bound.findCanonicalTool(
                    &entry.server_binding_identity,
                    entry.tool_name,
                )
            else
                null;
            if (restored_entry != null) continue;
            const current_tool = if (restored_mcp_view) |*mcp_bound|
                mcp_bound.snapshot.findTool(
                    &entry.server_binding_identity,
                    entry.tool_name,
                )
            else
                null;
            var allowed_by_current = false;
            for (config.mcp_selectors) |current| {
                if (std.mem.eql(
                    u8,
                    &entry.server_binding_identity,
                    &current.server_binding_identity,
                ) and std.mem.eql(u8, entry.tool_name, current.tool_name)) {
                    allowed_by_current = true;
                    break;
                }
            }
            const identity = mcp_canonical.ToolIdentity{
                .server_binding_identity = entry.server_binding_identity,
                .name = entry.tool_name,
                .schema_fingerprint = entry.schema_fingerprint,
            };
            try authority_issue_seeds.append(allocator, .{
                .subsystem = .mcp,
                .reason = if (!allowed_by_current)
                    .authority_narrowed
                else if (current_tool != null)
                    .schema_changed
                else
                    .unavailable,
                .server_binding_identity = entry.server_binding_identity,
                .authority_binding = identity.permissionBinding(),
                .canonical_name = entry.tool_name,
            });
        }
    }
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
        .mcp_selection_transfer = &restored_mcp_selection,
        .mcp_invalidated_without_view = mcp_invalidated_without_view,
        .authority_issue_seeds = authority_issue_seeds.items,
        .budget_profile = config.budget_profile,
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
            .issues = if (self.authority_issues) |*issues| issues.items else &.{},
        },
    };
}

const AuthorityIssueJson = struct {
    issue_id: []const u8,
    subsystem: []const u8,
    reason: []const u8,
    skill_id: ?[]const u8,
    permission_rule_id: ?[]const u8,
    server_binding_identity: ?[]const u8,
    authority_binding: ?[]const u8,
    canonical_name: ?[]const u8,
};

const SessionMcpToolJson = struct {
    model_name: []const u8,
    namespace: []const u8,
    canonical_name: []const u8,
    server_binding_identity: []const u8,
    schema_fingerprint: []const u8,
    permission_binding: []const u8,
    negotiated_protocol: []const u8,
};

const SessionDescriptionJson = struct {
    schema: []const u8 = "agentcore.session-description/v1",
    session_id: []const u8,
    origin: []const u8,
    lifecycle: []const u8,
    registered: bool,
    last_run_id: u64,
    last_compact_id: u64,
    checkpoint_generation: u64,
    policy_generation: u64,
    catalog_generation: u64,
    model: []const u8,
    conversation: struct {
        message_count: u64,
        compact_boundary: u64,
    },
    skill: struct {
        catalog_revision: ?[]const u8,
    },
    mcp: struct {
        selection_fingerprint: []const u8,
        tools: []const SessionMcpToolJson,
    },
    budget: struct {
        hard_bytes: u64,
        soft_bytes: u64,
        durable_usage_bytes: u64,
        available_bytes: u64,
        compaction_recommended: bool,
        last_outcome: []const u8,
        required_bytes: u64,
    },
    restore: struct {
        health: []const u8,
        invalidated_skill_authority: u32,
        invalidated_permission_rules: u32,
        invalidated_mcp_bindings: u32,
        issues: []const AuthorityIssueJson,
    },
};

const RestoreReportJson = struct {
    schema: []const u8 = "agentcore.restore-report/v1",
    health: []const u8,
    session_id: []const u8,
    checkpoint_generation: u64,
    policy_generation: u64,
    catalog_generation: u64,
    skill: struct {
        disposition: []const u8,
        checkpoint_enabled: u32,
        restored_enabled: u32,
        invalidated: u32,
    },
    permission: struct {
        restored_rules: u32,
        invalidated_rules: u32,
    },
    mcp: struct {
        restored_bindings: u32,
        invalidated_bindings: u32,
    },
    issues: []const AuthorityIssueJson,
};

fn encodeAuthorityIssues(
    output_allocator: std.mem.Allocator,
    issues: []const session_authority.AuthorityIssue,
) ![]AuthorityIssueJson {
    const result = try output_allocator.alloc(AuthorityIssueJson, issues.len);
    for (issues, result) |issue, *dto| dto.* = .{
        .issue_id = try lowerHexAlloc(output_allocator, &issue.issue_id),
        .subsystem = @tagName(issue.subsystem),
        .reason = @tagName(issue.reason),
        .skill_id = if (allZero(issue.skill_id[0..]))
            null
        else
            try output_allocator.dupe(u8, &issue.skill_id),
        .permission_rule_id = if (allZero(issue.permission_rule_id[0..]))
            null
        else
            try lowerHexAlloc(output_allocator, &issue.permission_rule_id),
        .server_binding_identity = if (allZero(issue.server_binding_identity[0..]))
            null
        else
            try lowerHexAlloc(output_allocator, &issue.server_binding_identity),
        .authority_binding = if (allZero(issue.authority_binding[0..]))
            null
        else
            try lowerHexAlloc(output_allocator, &issue.authority_binding),
        .canonical_name = if (issue.canonical_name.len == 0)
            null
        else
            issue.canonical_name,
    };
    return result;
}

fn encodeSessionDescription(
    output_allocator: std.mem.Allocator,
    description: *const session_authority.SessionDescription,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(output_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = try a.alloc(SessionMcpToolJson, description.mcp_tools.len);
    for (description.mcp_tools, tools) |tool, *dto| dto.* = .{
        .model_name = tool.model_name,
        .namespace = tool.namespace,
        .canonical_name = tool.canonical_name,
        .server_binding_identity = try lowerHexAlloc(a, &tool.server_binding_identity),
        .schema_fingerprint = try lowerHexAlloc(a, &tool.schema_fingerprint),
        .permission_binding = try lowerHexAlloc(a, &tool.permission_binding),
        .negotiated_protocol = tool.era.version(),
    };
    const dto = SessionDescriptionJson{
        .session_id = description.session_id.asSlice(),
        .origin = @tagName(description.origin),
        .lifecycle = @tagName(description.lifecycle),
        .registered = description.registered,
        .last_run_id = description.last_run_id,
        .last_compact_id = description.last_compact_id,
        .checkpoint_generation = description.checkpoint_generation,
        .policy_generation = description.policy_generation,
        .catalog_generation = description.catalog_generation,
        .model = description.model,
        .conversation = .{
            .message_count = description.conversation_messages,
            .compact_boundary = description.compact_boundary,
        },
        .skill = .{
            .catalog_revision = if (description.skill_revision) |*revision|
                revision
            else
                null,
        },
        .mcp = .{
            .selection_fingerprint = try lowerHexAlloc(a, &description.mcp_selection_fingerprint),
            .tools = tools,
        },
        .budget = .{
            .hard_bytes = description.budget.hard_bytes,
            .soft_bytes = description.budget.soft_bytes,
            .durable_usage_bytes = description.budget.durable_usage_bytes,
            .available_bytes = description.budget.available_bytes,
            .compaction_recommended = description.budget.compaction_recommended,
            .last_outcome = @tagName(description.budget.last_outcome),
            .required_bytes = description.budget.required_bytes,
        },
        .restore = .{
            .health = @tagName(description.restore_health),
            .invalidated_skill_authority = description.invalidated_skill_authority,
            .invalidated_permission_rules = description.invalidated_permission_rules,
            .invalidated_mcp_bindings = description.invalidated_mcp_bindings,
            .issues = try encodeAuthorityIssues(a, description.authority_issues),
        },
    };
    const encoded = std.json.Stringify.valueAlloc(output_allocator, dto, .{}) catch
        return error.OutOfMemory;
    if (encoded.len > wire.MAX_DESCRIPTION_JSON_BYTES_V1) {
        output_allocator.free(encoded);
        return error.ResourceLimit;
    }
    return encoded;
}

fn encodeRestoreReport(
    output_allocator: std.mem.Allocator,
    report: *const session_authority.RestoreReport,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(output_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dto = RestoreReportJson{
        .health = @tagName(report.health),
        .session_id = report.session_id.asSlice(),
        .checkpoint_generation = report.checkpoint_generation,
        .policy_generation = report.policy_generation,
        .catalog_generation = report.catalog_generation,
        .skill = .{
            .disposition = @tagName(report.skill.disposition),
            .checkpoint_enabled = report.skill.checkpoint_enabled,
            .restored_enabled = report.skill.restored_enabled,
            .invalidated = report.skill.invalidated,
        },
        .permission = .{
            .restored_rules = report.permission_rules_restored,
            .invalidated_rules = report.permission_rules_invalidated,
        },
        .mcp = .{
            .restored_bindings = report.mcp_bindings_restored,
            .invalidated_bindings = report.mcp_bindings_invalidated,
        },
        .issues = try encodeAuthorityIssues(a, report.issues),
    };
    const encoded = std.json.Stringify.valueAlloc(output_allocator, dto, .{}) catch
        return error.OutOfMemory;
    if (encoded.len > wire.MAX_DESCRIPTION_JSON_BYTES_V1) {
        output_allocator.free(encoded);
        return error.ResourceLimit;
    }
    return encoded;
}

fn sessionCreate(runtime_handle: ?*wire.RuntimeHandle, config_ptr: ?*const wire.SessionCreateConfigV1, callbacks_ptr: ?*const wire.SessionCallbacksV1, out_session: ?*?*wire.SessionHandle, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    if (out_session) |out| out.* = null;
    emptyError(out_error);
    const runtime = runtimeFrom(runtime_handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "runtime is required", out_error));
    var runtime_call = runtime.catalogs.enterCall() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    defer runtime_call.deinit();
    const config = config_ptr orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session config is required", out_error);
    const host = config.host orelse return fail(wire.STATUS_INVALID_ARGUMENT, "Session Host config is required", out_error);
    const callbacks = callbacks_ptr orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session callbacks are required", out_error);
    const out = out_session orelse return fail(wire.STATUS_INVALID_ARGUMENT, "out_session is required", out_error);
    if (config.struct_size != @sizeOf(wire.SessionCreateConfigV1) or config.reserved0 != 0 or !allZero(config.reserved) or
        host.struct_size != @sizeOf(wire.SessionHostConfigV1) or !allZero(host.reserved) or
        callbacks.struct_size != @sizeOf(wire.SessionCallbacksV1) or callbacks.reserved0 != 0 or
        !allZero(callbacks.reserved) or callbacks.on_event == null or
        (callbacks.on_ui_request != null and callbacks.release_response == null))
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid Session create, Host, or callback config", out_error);
    const kind = provider(host.provider_kind_code) orelse return fail(wire.STATUS_INVALID_ARGUMENT, "unknown provider", out_error);
    const mode = permissionMode(host.permission_mode_code) orelse return fail(wire.STATUS_INVALID_ARGUMENT, "unknown permission mode", out_error);
    const shell = shellPolicy(host.shell_policy_code) orelse return fail(wire.STATUS_INVALID_ARGUMENT, "unknown shell policy", out_error);
    var session_metadata: u64 = 0;
    for ([_]wire.BytesViewV1{
        host.api_key,
        config.model,
        host.base_url,
        host.workspace_root,
        host.workspace_home,
    }) |value| {
        addMetadata(&session_metadata, value.len, wire.MAX_SESSION_METADATA_BYTES_V1) catch |err|
            return failError(inputErrorStatus(err), err, out_error);
    }
    const api_key = text(host.api_key) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const model = text(config.model) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const base_url = text(host.base_url) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const root = text(host.workspace_root) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const home = text(host.workspace_home) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    if (api_key.len == 0 or model.len == 0 or root.len == 0) return fail(wire.STATUS_INVALID_ARGUMENT, "api_key, model and workspace_root are required", out_error);
    var workspace = skill_catalog_handles.CanonicalWorkspace.init(
        allocator,
        root,
        home,
    ) catch |err| return failError(catalogLifecycleStatus(err), err, out_error);
    defer workspace.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const initial_catalog = if (host.skill_catalog) |catalog_handle|
        catalogFrom(catalog_handle)
    else
        null;
    if ((initial_catalog == null) != (host.skill_policy == null))
        return fail(wire.STATUS_INVALID_ARGUMENT, "Skill Catalog and policy must be bound together", out_error);
    const initial_selection = if (host.skill_policy) |policy|
        parseSkillPolicy(scratch.allocator(), policy, initial_catalog.?.snapshot()) catch |err|
            return failError(inputErrorStatus(err), err, out_error)
    else
        null;
    const initial_permission_rules = if (host.permission_rules) |rules|
        parsePermissionRuleSet(scratch.allocator(), rules) catch |err|
            return failError(inputErrorStatus(err), err, out_error)
    else
        null;
    const workspace_scope_id = runtime.catalogs.scopeId(&workspace) catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    var initial_binding = createInitialSkillBinding(
        runtime,
        &workspace_scope_id,
        initial_catalog,
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
        host.allowed_tools,
        host.allowed_tool_count,
        &session_metadata,
        wire.MAX_SESSION_METADATA_BYTES_V1,
    ) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    const initial_mcp_selection = parseMcpSelection(
        scratch.allocator(),
        host.mcp_selection,
        &session_metadata,
    ) catch |err| return failError(inputErrorStatus(err), err, out_error);
    const budget_profile = parseDurableBudget(host.durable_budget) catch |err|
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
        .mcp_selectors = initial_mcp_selection,
        .budget_profile = budget_profile,
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

fn sessionRestore(
    runtime_handle: ?*wire.RuntimeHandle,
    config_ptr: ?*const wire.SessionRestoreConfigV1,
    callbacks_ptr: ?*const wire.SessionCallbacksV1,
    out_session: ?*?*wire.SessionHandle,
    out_report: ?*wire.OwnedBytesV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_session) |out| out.* = null;
    if (out_report) |out| out.* = .{ .ptr = null, .len = 0 };
    emptyError(out_error);
    const runtime = runtimeFrom(runtime_handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "runtime is required", out_error));
    const config = config_ptr orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "restore config is required", out_error);
    const host = config.host orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "Session Host config is required", out_error);
    const callbacks = callbacks_ptr orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "Session callbacks are required", out_error);
    const source_raw = config.source orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "checkpoint source is required", out_error);
    const limits_raw = config.limits orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "checkpoint limits are required", out_error);
    const session_out = out_session orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_session is required", out_error);
    const report_out = out_report orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_restore_report_json is required", out_error);
    if (config.struct_size != @sizeOf(wire.SessionRestoreConfigV1) or
        config.reserved0 != 0 or !allZero(config.reserved) or
        host.struct_size != @sizeOf(wire.SessionHostConfigV1) or
        !allZero(host.reserved) or
        callbacks.struct_size != @sizeOf(wire.SessionCallbacksV1) or
        callbacks.reserved0 != 0 or !allZero(callbacks.reserved) or
        callbacks.on_event == null or
        (callbacks.on_ui_request != null and callbacks.release_response == null) or
        source_raw.struct_size != @sizeOf(wire.CheckpointSourceV1) or
        source_raw.reserved0 != 0 or !allZero(source_raw.reserved) or
        source_raw.read == null)
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid restore, Host, callback, or source config", out_error);
    var runtime_call = runtime.catalogs.enterCall() catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    defer runtime_call.deinit();
    const kind = provider(host.provider_kind_code) orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "unknown provider", out_error);
    const mode = permissionMode(host.permission_mode_code) orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "unknown permission mode", out_error);
    const shell = shellPolicy(host.shell_policy_code) orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "unknown shell policy", out_error);
    var session_metadata: u64 = 0;
    for ([_]wire.BytesViewV1{
        host.api_key,
        host.base_url,
        host.workspace_root,
        host.workspace_home,
    }) |value| addMetadata(
        &session_metadata,
        value.len,
        wire.MAX_SESSION_METADATA_BYTES_V1,
    ) catch |err| return failError(inputErrorStatus(err), err, out_error);
    const api_key = text(host.api_key) catch |err|
        return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const base_url = text(host.base_url) catch |err|
        return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const root = text(host.workspace_root) catch |err|
        return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const home = text(host.workspace_home) catch |err|
        return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    if (api_key.len == 0 or root.len == 0)
        return fail(wire.STATUS_INVALID_ARGUMENT, "api_key and workspace_root are required", out_error);
    var workspace = skill_catalog_handles.CanonicalWorkspace.init(
        allocator,
        root,
        home,
    ) catch |err| return failError(catalogLifecycleStatus(err), err, out_error);
    defer workspace.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const current_catalog = if (host.skill_catalog) |catalog_handle|
        catalogFrom(catalog_handle)
    else
        null;
    if ((current_catalog == null) != (host.skill_policy == null))
        return fail(wire.STATUS_INVALID_ARGUMENT, "Skill Catalog and policy must be bound together", out_error);
    const parsed_skill_policy = if (host.skill_policy) |policy|
        parseSkillPolicy(scratch.allocator(), policy, current_catalog.?.snapshot()) catch |err|
            return failError(inputErrorStatus(err), err, out_error)
    else
        null;
    const permission_rules = if (host.permission_rules) |rules|
        parsePermissionRuleSet(scratch.allocator(), rules) catch |err|
            return failError(inputErrorStatus(err), err, out_error)
    else
        null;
    const allowed = borrowedViews(
        scratch.allocator(),
        host.allowed_tools,
        host.allowed_tool_count,
        &session_metadata,
        wire.MAX_SESSION_METADATA_BYTES_V1,
    ) catch |err| return failError(inputErrorStatus(err), err, out_error);
    const mcp_selectors = parseMcpSelection(
        scratch.allocator(),
        host.mcp_selection,
        &session_metadata,
    ) catch |err| return failError(inputErrorStatus(err), err, out_error);
    const budget_profile = parseDurableBudget(host.durable_budget) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    const limits = parseCheckpointLimits(limits_raw) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    if (shell == .sandboxed) sandbox_admission.validate(allocator) catch |err|
        return failError(
            if (err == error.OutOfMemory) wire.STATUS_OUT_OF_MEMORY else wire.STATUS_INVALID_ARGUMENT,
            err,
            out_error,
        );
    const workspace_scope_id = runtime.catalogs.scopeId(&workspace) catch |err|
        return failError(catalogLifecycleStatus(err), err, out_error);
    var current_skill_binding = createInitialSkillBinding(
        runtime,
        &workspace_scope_id,
        current_catalog,
        if (parsed_skill_policy) |*selection| selection else null,
    ) catch |err| return failError(
        if (err == error.InvalidSkillBinding)
            wire.STATUS_INVALID_ARGUMENT
        else
            catalogLifecycleStatus(err),
        err,
        out_error,
    );
    defer if (current_skill_binding) |*binding|
        binding.deinit(&runtime.catalogs);
    var source = AbiCheckpointSource{ .descriptor = source_raw.* };
    const restored = restoreCheckpoint(
        runtime,
        .{
            .callbacks = callbacks.*,
            .provider_kind = kind,
            .api_key = api_key,
            .base_url = if (base_url.len == 0) null else base_url,
            .permission_mode = mode,
            .permission_rules = permission_rules,
            .workspace = .{ .root = workspace.root, .home = workspace.home, .shell = shell },
            .allowed_tools = allowed,
            .mcp_selectors = mcp_selectors,
            .workspace_scope_id = workspace_scope_id,
            .budget_profile = budget_profile,
        },
        &current_skill_binding,
        source.interface(),
        limits,
    ) catch |err| return failError(switch (err) {
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
        error.InvalidBudget, error.InvalidProfile, error.InvalidSkillBinding => wire.STATUS_INVALID_ARGUMENT,
        error.Corrupt, error.InvalidState => wire.STATUS_CHECKPOINT_CORRUPT,
        error.UnsupportedSchema,
        error.PermissionStateUnsupported,
        error.McpStateUnsupported,
        => wire.STATUS_CHECKPOINT_UNSUPPORTED,
        error.IncompatibleAbi => wire.STATUS_CHECKPOINT_INCOMPATIBLE,
        error.SourceFailed => wire.STATUS_CHECKPOINT_IO,
        error.SessionAlreadyOpen => wire.STATUS_LOGICAL_SESSION_CONFLICT,
        error.RuntimeUnavailable => wire.STATUS_INVALID_STATE,
        else => wire.STATUS_CORE_ERROR,
    }, err, out_error);
    const encoded_report = encodeRestoreReport(allocator, &restored.report) catch |err| {
        std.debug.assert(restored.session.tryBeginDestroy());
        restored.session.core_session.destroy() catch unreachable;
        deinitAbiSession(restored.session, runtime);
        return failError(inputErrorStatus(err), err, out_error);
    };
    report_out.* = .{ .ptr = encoded_report.ptr, .len = encoded_report.len };
    session_out.* = restored.session.handle();
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
    deinitAbiSession(self, runtime);
    return wire.STATUS_OK;
}

fn deinitAbiSession(self: *AbiSession, runtime: *AbiRuntime) void {
    self.clearStagedPermission();
    self.run_state_projector.deinit();
    if (self.policy_root) |root_frame| {
        root_frame.release();
        self.policy_root = null;
    }
    if (self.skill_binding) |*binding| {
        binding.deinit(&runtime.catalogs);
        self.skill_binding = null;
    }
    if (self.mcp_selection) |*selection| {
        selection.deinit();
        self.mcp_selection = null;
    }
    if (self.permission_audit) |*audit| audit.deinit();
    if (self.authority_issues) |*issues| issues.deinit();
    self.permission_state.deinit();
    allocator.destroy(self);
}

fn sessionDescribe(
    handle: ?*wire.SessionHandle,
    out_description: ?*wire.OwnedBytesV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_description) |out| out.* = .{ .ptr = null, .len = 0 };
    emptyError(out_error);
    const self = sessionFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    const out = out_description orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "out_description_json is required", out_error);
    var description = self.describe(allocator) catch |err|
        return failError(switch (err) {
            error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
            error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
            error.SessionBusy => wire.STATUS_BUSY,
            error.InvalidSessionState => wire.STATUS_INVALID_STATE,
            else => wire.STATUS_CORE_ERROR,
        }, err, out_error);
    defer description.deinit();
    const encoded = encodeSessionDescription(allocator, &description) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    out.* = .{ .ptr = encoded.ptr, .len = encoded.len };
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
    self.setModelAdmitted(model) catch |err|
        return failError(sessionMutationStatus(err), err, out_error);
    return wire.STATUS_OK;
}

fn sessionUpdateSkills(
    handle: ?*wire.SessionHandle,
    optional_catalog_handle: ?*wire.SkillCatalogHandle,
    policy_ptr: ?*const wire.SkillPolicyV1,
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
    const policy = policy_ptr orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "Skill policy is required", out_error);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const optional_catalog = if (optional_catalog_handle) |catalog_handle|
        catalogFrom(catalog_handle)
    else
        null;
    const target_snapshot = if (optional_catalog) |catalog|
        catalog.snapshot()
    else if (self.skill_binding) |*binding|
        binding.snapshot()
    else
        return fail(wire.STATUS_INVALID_STATE, "Skill Catalog is not bound", out_error);
    const spec = parseSkillPolicy(scratch.allocator(), policy, target_snapshot) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    self.updateSkillsAdmitted(
        runtime,
        optional_catalog,
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

fn sessionUpdateMcp(
    handle: ?*wire.SessionHandle,
    selection_ptr: ?*const wire.McpSelectionV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    emptyError(out_error);
    const self = sessionFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    const selection = selection_ptr orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "MCP selection is required", out_error);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var metadata: u64 = 0;
    const selectors = parseMcpSelection(
        scratch.allocator(),
        selection,
        &metadata,
    ) catch |err| return failError(inputErrorStatus(err), err, out_error);
    self.updateMcpSelection(selectors, .fresh) catch |err|
        return failError(switch (err) {
            error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
            error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
            error.CheckpointBudgetRequired => wire.STATUS_CHECKPOINT_BUDGET_REQUIRED,
            error.NotRefreshed => wire.STATUS_MCP_NOT_REFRESHED,
            error.InvalidSelection, error.InvalidMcpBinding => wire.STATUS_INVALID_MCP_SELECTION,
            error.SessionBusy => wire.STATUS_BUSY,
            error.InvalidSessionState => wire.STATUS_INVALID_STATE,
            else => wire.STATUS_CORE_ERROR,
        }, err, out_error);
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
    self.pending_permission = null;
    self.clearStagedPermission();
    // This defer is the facade completion linearization point. Everything that
    // reads AbiSession or publishes RunResult/diagnostics happens before it;
    // after it releases the gate, sessionDestroy may immediately free `self`.
    defer {
        self.pending_permission = null;
        self.clearStagedPermission();
        self.finishRun();
    }
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
                if (err == error.CheckpointBudgetRequired)
                    writeRunBudgetFields(self, out);
                if (err == error.AdmittedCleanupFailed or
                    self.core_session.isPoisoned())
                {
                    if (self.core_session.isPoisoned()) self.emitPoisonedRunState(run_id);
                    self.facade_poisoned.store(true, .release);
                }
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
                if (err == error.CheckpointBudgetRequired)
                    writeRunBudgetFields(self, out);
                if (err == error.AdmittedCleanupFailed or
                    self.core_session.isPoisoned())
                {
                    if (self.core_session.isPoisoned()) self.emitPoisonedRunState(run_id);
                    self.facade_poisoned.store(true, .release);
                }
                return failError(status, err, out_error);
            };
        },
        else => return fail(wire.STATUS_INVALID_ARGUMENT, "unknown RunInputV1 kind", out_error),
    };
    // Budget-aware paths already recorded their stronger terminal kind. Keep
    // this fallback for any pre-budget internal fixture path.
    if (self.last_terminal_id != run_id)
        self.recordTerminal(.run, run_id);
    const result = switch (execution) {
        .aborted => {
            out.* = .{
                .struct_size = @sizeOf(wire.RunResultV1),
                .stop_reason_code = wire.STOP_ABORTED,
                .turns = 0,
                .tool_calls = 0,
                .checkpoint_outcome_code = 0,
                .result_flags = 0,
                .durable_usage_bytes = 0,
                .required_checkpoint_bytes = 0,
                .reserved = [_]u64{0} ** 4,
            };
            writeRunBudgetFields(self, out);
            invokeTestEpilogueHook(run_id);
            return wire.STATUS_OK;
        },
        .completed => |completed| completed,
    };
    defer if (result.suspend_info) |suspend_info| suspend_info.deinit();
    invokeTestEpilogueHook(run_id);
    const stop_code = switch (self.budget_state.last_outcome) {
        .budget_exhausted => wire.STOP_CHECKPOINT_BUDGET_EXHAUSTED,
        .resource_limit => wire.STOP_CHECKPOINT_RESOURCE_LIMIT,
        .none, .budget_required => stopReason(self, result.stop_reason) catch
            return fail(wire.STATUS_INTERNAL_ERROR, "core returned a stop reason unsupported by AgentCore ABI v1", out_error),
    };
    out.* = .{
        .struct_size = @sizeOf(wire.RunResultV1),
        .stop_reason_code = stop_code,
        .turns = result.turns,
        .tool_calls = result.tool_calls,
        .checkpoint_outcome_code = 0,
        .result_flags = 0,
        .durable_usage_bytes = 0,
        .required_checkpoint_bytes = 0,
        .reserved = [_]u64{0} ** 4,
    };
    writeRunBudgetFields(self, out);
    return wire.STATUS_OK;
}

fn writeRunBudgetFields(self: *const AbiSession, out: *wire.RunResultV1) void {
    const budget = self.budget_state.describe();
    out.struct_size = @sizeOf(wire.RunResultV1);
    out.checkpoint_outcome_code = switch (budget.last_outcome) {
        .none => wire.RUN_CHECKPOINT_NONE,
        .budget_required => wire.RUN_CHECKPOINT_BUDGET_REQUIRED,
        .budget_exhausted => wire.RUN_CHECKPOINT_BUDGET_EXHAUSTED,
        .resource_limit => wire.RUN_CHECKPOINT_RESOURCE_LIMIT,
    };
    out.result_flags = if (budget.compaction_recommended)
        wire.RUN_RESULT_COMPACTION_RECOMMENDED
    else
        0;
    out.durable_usage_bytes = budget.durable_usage_bytes;
    out.required_checkpoint_bytes = budget.required_bytes;
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
    const report = self.compactBudgeted(operation_id) catch |err|
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

fn sessionExportCheckpoint(
    handle: ?*wire.SessionHandle,
    config_ptr: ?*const wire.CheckpointExportConfigV1,
    out_result: ?*wire.CheckpointExportResultV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_result) |out| out.* = std.mem.zeroes(wire.CheckpointExportResultV1);
    emptyError(out_error);
    const self = sessionFrom(handle orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    const config = config_ptr orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "checkpoint export config is required", out_error);
    const out = out_result orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "checkpoint export result is required", out_error);
    const limits_raw = config.limits orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "checkpoint limits are required", out_error);
    const sink_raw = config.sink orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "checkpoint sink is required", out_error);
    if (config.struct_size != @sizeOf(wire.CheckpointExportConfigV1) or
        config.reserved0 != 0 or !allZero(config.reserved) or
        sink_raw.struct_size != @sizeOf(wire.CheckpointSinkV1) or
        sink_raw.reserved0 != 0 or !allZero(sink_raw.reserved) or
        sink_raw.write == null)
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid checkpoint export or sink config", out_error);
    const limits = parseCheckpointLimits(limits_raw) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    var sink = AbiCheckpointSink{ .descriptor = sink_raw.* };
    const report = self.exportCheckpoint(limits, sink.interface()) catch |err|
        return failError(switch (err) {
            error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
            error.InvalidBudget => wire.STATUS_INVALID_ARGUMENT,
            error.ResourceLimit => wire.STATUS_RESOURCE_LIMIT,
            error.SinkFailed => wire.STATUS_CHECKPOINT_IO,
            error.SessionBusy, error.RuntimeBusy => wire.STATUS_BUSY,
            error.InvalidSessionState, error.RuntimeUnavailable => wire.STATUS_INVALID_STATE,
            else => wire.STATUS_CORE_ERROR,
        }, err, out_error);
    out.* = .{
        .struct_size = @sizeOf(wire.CheckpointExportResultV1),
        .reserved0 = 0,
        .checkpoint_generation = self.checkpoint_generation,
        .total_bytes = report.total_bytes,
        .chunk_count = report.chunk_count,
        .digest = report.digest,
        .reserved = [_]u64{0} ** 4,
    };
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
    .runtime_refresh_mcp = runtimeRefreshMcp,
    .runtime_describe_mcp = runtimeDescribeMcp,
    .runtime_apply_mcp_configuration = runtimeApplyMcpConfiguration,
    .session_create = sessionCreate,
    .session_restore = sessionRestore,
    .session_destroy = sessionDestroy,
    .session_describe = sessionDescribe,
    .session_set_model = sessionSetModel,
    .session_update_skills = sessionUpdateSkills,
    .session_update_permission_rules = sessionUpdatePermissionRules,
    .session_update_mcp = sessionUpdateMcp,
    .session_run_input = sessionRunInput,
    .session_abort = sessionAbort,
    .session_compact = sessionCompact,
    .session_abort_compact = sessionAbortCompact,
    .session_export_checkpoint = sessionExportCheckpoint,
    .buffer_release = bufferRelease,
    .completion_create = completionCreate,
    .completion_destroy = completionDestroy,
    .completion_describe = completionDescribe,
    .completion_complete = completionComplete,
    .completion_stream_start = completionStreamStart,
    .completion_stream_next = completionStreamNext,
    .completion_stream_abort = completionStreamAbort,
    .completion_stream_destroy = completionStreamDestroy,
    .reserved = [_]u64{0} ** 3,
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

const CompactBudgetTestProvider = struct {
    allocator: std.mem.Allocator,
    payload_bytes: usize,
    calls: u32 = 0,
    stream: Stream = undefined,

    fn provider(self: *@This()) core.api_provider.Provider {
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

    fn model(_: *anyopaque) []const u8 {
        return "compact-budget-test";
    }

    fn sendStream(
        raw: *anyopaque,
        _: []const core.types.ApiMessage,
        _: ?[]const u8,
        _: ?[]const core.json.ToolDefinition,
        _: ?*const core.util_abort.AbortSignal,
        _: ?[]const u8,
        _: ?core.json.ToolChoice,
        _: []const u8,
    ) anyerror!core.api_provider.StreamHandle {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.stream = .{
            .allocator = self.allocator,
            .payload_bytes = self.payload_bytes,
            .request_id = core.util_log.genRequestId(),
        };
        return self.stream.handle();
    }

    fn sendStreamRetry(
        raw: *anyopaque,
        messages: []const core.types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const core.json.ToolDefinition,
        abort: ?*const core.util_abort.AbortSignal,
        model_override: ?[]const u8,
        tool_choice: ?core.json.ToolChoice,
        _: u32,
        _: u64,
        _: ?core.api_provider.RetryReporter,
        user_query: []const u8,
    ) anyerror!core.api_provider.StreamHandle {
        return sendStream(
            raw,
            messages,
            system,
            tools,
            abort,
            model_override,
            tool_choice,
            user_query,
        );
    }

    fn send(
        _: *anyopaque,
        _: []const core.types.ApiMessage,
        _: ?[]const u8,
        _: ?[]const core.json.ToolDefinition,
        _: ?[]const u8,
    ) anyerror!core.api_provider.ApiResponse {
        return error.Unused;
    }

    fn maxTokens(_: *anyopaque) u32 {
        return 1024;
    }

    fn maxInputTokens(_: *anyopaque) u32 {
        return 200_000;
    }

    fn reasoningEffort(_: *anyopaque) ?core.types.ReasoningEffort {
        return null;
    }

    fn supports(_: *anyopaque, _: core.api_provider.Capability) bool {
        return false;
    }

    const Stream = struct {
        allocator: std.mem.Allocator,
        payload_bytes: usize,
        request_id: core.util_log.RequestId,
        emitted: bool = false,

        fn handle(self: *@This()) core.api_provider.StreamHandle {
            return .{
                .ctx = self,
                .nextFn = next,
                .deinitFn = deinit,
                .stopReasonFn = Stream.stopReason,
                .requestIdFn = requestId,
            };
        }

        fn next(raw: *anyopaque) anyerror!?core.api_stream.StreamEvent {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.emitted) return null;
            self.emitted = true;
            const bytes = try self.allocator.alloc(u8, self.payload_bytes);
            @memset(bytes, 's');
            return .{ .text = bytes };
        }

        fn deinit(_: *anyopaque) void {}

        fn stopReason(_: *anyopaque) core.api_stream.StopReason {
            return .end_turn;
        }

        fn requestId(raw: *anyopaque) core.util_log.RequestId {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.request_id;
        }
    };
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

test "Revision 9 hard-cut MCP response descriptor preserves HTTP fact and releases the body field" {
    const Probe = struct {
        var status: u32 = wire.MCP_EXCHANGE_RESPONSE;
        var http_status: u32 = 400;
        var releases: usize = 0;
        var body_field: ?*wire.OwnedBytesV1 = null;
        var released_field: ?*wire.OwnedBytesV1 = null;
        var empty_body = false;
        const payload = "legacy rejection";

        fn request(
            _: ?*anyopaque,
            _: ?*anyopaque,
            _: wire.BytesViewV1,
            _: u32,
            _: ?*const wire.McpCancellationV1,
            out_response: ?*wire.McpResponseV1,
        ) callconv(.c) u32 {
            const out = out_response orelse return wire.MCP_EXCHANGE_FATAL;
            out.* = .{
                .struct_size = @sizeOf(wire.McpResponseV1),
                .http_status = http_status,
                .body = if (empty_body)
                    .{ .ptr = null, .len = 0 }
                else
                    .{ .ptr = @constCast(payload.ptr), .len = payload.len },
                .reserved = [_]u64{0} ** 2,
            };
            body_field = &out.body;
            return status;
        }

        fn release(
            _: ?*anyopaque,
            _: ?*anyopaque,
            response: ?*wire.OwnedBytesV1,
        ) callconv(.c) void {
            releases += 1;
            released_field = response;
        }
    };
    var descriptor = std.mem.zeroes(wire.McpConnectorV1);
    descriptor.struct_size = @sizeOf(wire.McpConnectorV1);
    descriptor.request = Probe.request;
    descriptor.release_response = Probe.release;
    var host_connection: u8 = 0;
    var connection = AbiMcpConnection{
        .descriptor = descriptor,
        .transport = .streamable_http,
        .max_frame_bytes = 1024,
        .host_connection = @ptrCast(&host_connection),
    };

    Probe.status = wire.MCP_EXCHANGE_RESPONSE;
    Probe.http_status = 400;
    Probe.releases = 0;
    Probe.body_field = null;
    Probe.released_field = null;
    Probe.empty_body = false;
    const outcome = try AbiMcpConnection.request(
        &connection,
        std.testing.allocator,
        "{}",
        1000,
        .{},
    );
    defer std.testing.allocator.free(outcome.response.body);
    try std.testing.expectEqual(@as(u32, 400), outcome.response.http_status);
    try std.testing.expectEqualStrings(Probe.payload, outcome.response.body);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    try std.testing.expect(Probe.released_field == Probe.body_field);

    Probe.http_status = 204;
    Probe.releases = 0;
    Probe.empty_body = true;
    const empty_outcome = try AbiMcpConnection.request(
        &connection,
        std.testing.allocator,
        "{}",
        1000,
        .{},
    );
    defer std.testing.allocator.free(empty_outcome.response.body);
    try std.testing.expectEqual(@as(u32, 204), empty_outcome.response.http_status);
    try std.testing.expectEqual(@as(usize, 0), empty_outcome.response.body.len);
    try std.testing.expectEqual(@as(usize, 0), Probe.releases);

    Probe.status = wire.MCP_EXCHANGE_RESPONSE;
    Probe.http_status = 400;
    Probe.releases = 0;
    Probe.empty_body = false;
    connection.max_frame_bytes = 1;
    try std.testing.expectError(
        error.InvalidConnectorResponse,
        AbiMcpConnection.request(&connection, std.testing.allocator, "{}", 1000, .{}),
    );
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    connection.max_frame_bytes = 1024;

    Probe.status = wire.MCP_EXCHANGE_SERVER_ERROR;
    Probe.http_status = 0;
    Probe.releases = 0;
    Probe.body_field = null;
    Probe.released_field = null;
    try std.testing.expectError(
        error.InvalidConnectorResponse,
        AbiMcpConnection.request(&connection, std.testing.allocator, "{}", 1000, .{}),
    );
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    try std.testing.expect(Probe.released_field == Probe.body_field);
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
    const PublishPermission = struct {
        fn call(
            session: *AbiSession,
            run_id: u64,
            tool_call_id: []const u8,
            tool_name: []const u8,
            allowed: bool,
        ) bool {
            return session.publishStagedPermission(
                session.core_session.session_id,
                run_id,
                .{ .policy_decision = .{
                    .trace_id = [_]u8{0} ** 12,
                    .depth = 0,
                    .id = tool_call_id,
                    .tool = tool_name,
                    .decision = if (allowed) "allow" else "deny",
                    .source = "test",
                    .allowed = allowed,
                } },
            );
        }
    };

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

    // Fork children inherit the exact Session grant but not the parent's Host
    // UI capability. An unresolved Core safety prompt is denied locally and
    // cannot leave a pending request behind or invoke the callback.
    const ChildSink = struct {
        fn emit(
            _: *anyopaque,
            _: core.session_id.SessionId,
            _: core.protocol.ui_event.CoreEvent,
        ) void {}
        fn poll(
            _: *anyopaque,
            _: core.session_id.SessionId,
        ) ?core.protocol.ui_event.UiEvent {
            return null;
        }
    };
    var child_sink_marker: u8 = 0;
    const child_downstream = core.protocol.ui_backend.UiBackend{
        .ctx = &child_sink_marker,
        .emit = ChildSink.emit,
        .poll = ChildSink.poll,
    };
    var child_projector = event_projection.Projector.init(
        std.testing.allocator,
        .model_tool,
        &child_downstream,
    );
    defer child_projector.deinit();
    {
        const saved_override = native_session.permission_ctx.decision_override;
        native_session.permission_ctx.decision_override = .{
            .ctx = &fake,
            .decideFn = AbiSession.permissionDecisionOverride,
        };
        defer native_session.permission_ctx.decision_override = saved_override;
        var child_lease = child_permission.Lease{};
        child_lease.init(fake.permissionForkOwner(), &child_projector);
        defer child_lease.deinit();
        const child_ctx = child_lease.permissionContext();
        const child_backend = child_projector.backend();
        child_backend.emitEvent(native_session.session_id, .{ .tool_start = .{
            .id = "child-call-allow",
            .name = "Bash",
            .input = "{}",
        } });
        const child_call_id = try fake.copyPermissionToolCallId(
            std.testing.allocator,
            "Bash",
            "{}",
        );
        defer std.testing.allocator.free(child_call_id);
        try std.testing.expectEqualStrings("child-call-allow", child_call_id);
        try std.testing.expectEqual(
            core.permission.PermissionResult.allow,
            core.permission.checkPermission(child_ctx, "Bash", "{}"),
        );
        try std.testing.expectEqual(
            core.permission.PermissionResult.deny,
            child_ctx.decision_override.?.decide(
                "Bash",
                "{}",
                .ask,
            ).?,
        );
        try std.testing.expectEqual(
            core.permission.PermissionResult.ask,
            core.permission.checkPermission(child_ctx, "Edit", "{}"),
        );
        const calls_before_child_prompt = Probe.calls;
        try std.testing.expect(!try core.permission.promptUser(
            child_ctx,
            "Edit",
            "{}",
        ));
        try std.testing.expectEqual(calls_before_child_prompt, Probe.calls);
        try std.testing.expect(fake.pending_permission == null);
        try std.testing.expect(fake.active_permission_trace == &child_projector);
    }
    try std.testing.expect(fake.active_permission_trace == null);
    try std.testing.expect(fake.pending_permission == null);

    // Session memory belongs only to the logical Session that received the
    // answer. A fresh Session over the same Runtime and Workspace must ask
    // again; no process-wide or product-settings authority is inherited.
    const fresh_native_session = try native_runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{
            .root = root_buffer[0..root_len],
            .shell = .unrestricted,
        },
        .allowed_tools = &.{ "Bash", "Write", "Edit" },
    });
    defer fresh_native_session.destroy() catch unreachable;
    var fresh = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = fresh_native_session,
    };
    defer fresh.permission_state.deinit();
    try std.testing.expectEqual(@as(usize, 0), fresh.permission_state.ruleCount());
    try std.testing.expect(
        AbiSession.permissionDecisionOverride(
            &fresh,
            "Bash",
            "{}",
            .undecided,
        ) == null,
    );

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

    // Audit ownership is prepared before Session authority publication. An
    // allocation failure therefore leaves the existing grant set untouched.
    var failing_audit = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    {
        fake.permission_audit.?.allocator = failing_audit.allocator();
        defer fake.permission_audit.?.allocator = std.testing.allocator;
        Probe.permission = "deny_session";
        try ToolCall.append(native_session, "call-audit-failure", "Write", "{}");
        try std.testing.expect(
            AbiSession.permissionDecisionOverride(
                &fake,
                "Write",
                "{}",
                .undecided,
            ) == null,
        );
        const grants_before_audit_failure = fake.permission_state.ruleCount();
        try std.testing.expectError(
            error.OutOfMemory,
            AbiSession.requestUi(&fake, .{
                .session_id = native_session.session_id,
                .run_id = 2,
            }, std.testing.allocator, &write_request, &response),
        );
        try std.testing.expectEqual(
            grants_before_audit_failure,
            fake.permission_state.ruleCount(),
        );
        try std.testing.expectEqual(@as(usize, 0), fake.permission_audit.?.count());
        try std.testing.expect(!PublishPermission.call(
            &fake,
            2,
            "call-audit-failure",
            "Write",
            false,
        ));
        fake.callback_status.store(wire.STATUS_OK, .release);
    }

    // A Host answer is not the authorization decision. If durable Session
    // authority cannot be reserved, the final policy event denies execution
    // and commits one receipt containing both facts.
    const budget_profile = session_budget.Profile{
        .hard_bytes = 4096,
        .soft_bytes = 3072,
        .input_cap_bytes = 1024,
        .provider_request_cap_bytes = 1024,
        .provider_result_cap_bytes = 512,
        .tool_result_cap_bytes = 256,
        .mcp_result_cap_bytes = 256,
        .audit_reserve_bytes = 128,
        .terminal_reserve_bytes = 128,
    };
    var denied_budget = session_budget.Controller.init(
        std.testing.allocator,
        budget_profile,
        .{
            .input_delta_bytes = 0,
            .projected_usage_bytes = 3900,
            .minimum_required_bytes = 3900,
        },
    );
    fake.active_budget_controller = &denied_budget;
    Probe.permission = "allow_session";
    try ToolCall.append(native_session, "call-budget-deny", "Write", "{}");
    try std.testing.expect(
        AbiSession.permissionDecisionOverride(
            &fake,
            "Write",
            "{}",
            .undecided,
        ) == null,
    );
    try std.testing.expectError(
        error.BudgetExhausted,
        AbiSession.requestUi(&fake, .{
            .session_id = native_session.session_id,
            .run_id = 2,
        }, std.testing.allocator, &write_request, &response),
    );
    fake.active_budget_controller = null;
    try std.testing.expect(PublishPermission.call(
        &fake,
        2,
        "call-budget-deny",
        "Write",
        false,
    ));
    var budget_audit = (try fake.permission_audit.?.cloneLast(
        std.testing.allocator,
    )).?;
    defer budget_audit.deinit(std.testing.allocator);
    try std.testing.expectEqual(session_permission.Decision.deny, budget_audit.decision);
    try std.testing.expectEqual(session_permission.Response.allow_session, budget_audit.response.?);
    try std.testing.expectEqual(session_permission.CallbackOutcome.answered, budget_audit.callback_outcome.?);

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
    try std.testing.expect(PublishPermission.call(
        &fake,
        2,
        "call-deny",
        "Write",
        false,
    ));
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
    try std.testing.expect(PublishPermission.call(
        &fake,
        3,
        "call-once",
        "Edit",
        true,
    ));
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
    try std.testing.expect(PublishPermission.call(
        &fake,
        4,
        "call-dont-ask-safety",
        "Edit",
        false,
    ));
    try std.testing.expectEqual(calls_before_dont_ask, Probe.calls);
    native_session.permission_ctx.setMode(.default);

    // A callback answer is bound to the exact tool call that was shown to the
    // Host. A later policy event cannot substitute another call id even when
    // the model-facing tool name and arguments are identical.
    Probe.status = wire.UI_ANSWERED;
    Probe.permission = "allow_once";
    try ToolCall.append(native_session, "call-id-bound", "Edit", "{}");
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
            .run_id = 5,
        }, std.testing.allocator, &edit_request, &response),
    );
    try std.testing.expect(!PublishPermission.call(
        &fake,
        5,
        "call-id-substituted",
        "Edit",
        true,
    ));
    try std.testing.expectEqual(
        wire.STATUS_INTERNAL_ERROR,
        fake.callback_status.load(.acquire),
    );
    fake.callback_status.store(wire.STATUS_OK, .release);

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
    try std.testing.expect(PublishPermission.call(
        &fake,
        5,
        "call-unavailable",
        "Edit",
        false,
    ));
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
    try std.testing.expect(PublishPermission.call(
        &fake,
        6,
        "call-cancelled",
        "Edit",
        false,
    ));
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
    try std.testing.expect(PublishPermission.call(
        &fake,
        7,
        "call-contract",
        "Bash",
        false,
    ));
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
        session.active_mcp_environment = null;
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        const status = sessionDestroy(session.handle(), &diagnostic);
        bufferRelease(&diagnostic);
        std.debug.assert(status == wire.STATUS_OK);
    }
    var permission_run_view = (try session.materializeMcpRunView()).?;
    defer permission_run_view.deinit();
    var active_mcp_environment = try mcp_session.Environment.init(
        std.testing.allocator,
        &permission_run_view,
        session.core_session.tools.definitions,
        session.core_session.tools.dispatcher(),
        null,
    );
    defer active_mcp_environment.deinit();
    session.active_mcp_environment = &active_mcp_environment;
    const model_name = session.mcp_selection.?.entries[0].model_name;
    try std.testing.expectEqual(
        core.permission.PermissionResult.deny,
        core.permission.checkPermission(
            &session.core_session.permission_ctx,
            model_name,
            "[]",
        ),
    );
    try std.testing.expect(session.pending_permission == null);
    try std.testing.expectEqual(
        core.permission.PermissionResult.ask,
        core.permission.checkPermission(
            &session.core_session.permission_ctx,
            model_name,
            "{\"city\":7}",
        ),
    );
    try std.testing.expect(session.pending_permission != null);
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
        &session.mcp_selection.?.entries[0].permissionIdentity().binding,
        &pending.binding,
    );
    // This focused rule projection check runs outside a real admitted tool
    // call, so temporarily disable provenance recording; production explicit
    // decisions still require the real tool_call identity and fail closed.
    const saved_audit = session.permission_audit;
    session.permission_audit = null;
    defer session.permission_audit = saved_audit;
    try session.updatePermissionRules(.{
        .allow = &.{"mcp__weather__weather"},
    });
    try std.testing.expectEqual(
        core.permission.PermissionResult.allow,
        core.permission.checkPermission(
            &session.core_session.permission_ctx,
            model_name,
            "{\"city\":\"Paris\"}",
        ),
    );
    try session.updatePermissionRules(.{
        .ask = &.{"mcp__weather"},
    });
    try std.testing.expectEqual(
        core.permission.PermissionResult.ask,
        core.permission.checkPermission(
            &session.core_session.permission_ctx,
            model_name,
            "{\"city\":\"Paris\"}",
        ),
    );
    try session.updatePermissionRules(.{
        .deny = &.{"mcp__weather__*"},
    });
    try std.testing.expectEqual(
        core.permission.PermissionResult.deny,
        core.permission.checkPermission(
            &session.core_session.permission_ctx,
            model_name,
            "{\"city\":\"Paris\"}",
        ),
    );
    try session.updatePermissionRules(.{});
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
        session.mcp_selection.?.entries[0].model_name,
    );
    defer std.testing.allocator.free(old_model_name);
    const old_identity = session.mcp_selection.?.entries[0].permissionIdentity();
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
        session.updateMcpSelection(&selectors, .fresh),
    );
    session.call_state = .idle;
    try std.testing.expectEqual(@as(u64, 1), session.catalog_generation);
    try std.testing.expectEqual(@as(usize, 1), session.permission_state.ruleCount());
    const missing_selectors = [_]mcp_session.Selector{.{
        .server_binding_identity = binding,
        .tool_name = "missing",
    }};
    try std.testing.expectError(
        error.InvalidSelection,
        session.updateMcpSelection(&missing_selectors, .fresh),
    );
    try std.testing.expectEqual(@as(u64, 1), session.catalog_generation);
    try std.testing.expectEqual(@as(usize, 1), session.permission_state.ruleCount());

    server.input_schema_json =
        "{\"type\":\"object\",\"properties\":{\"country\":{\"type\":\"string\"}},\"required\":[\"country\"],\"additionalProperties\":false}";
    try std.testing.expectEqual(@as(u64, 2), try runtime.mcp_manager.?.refresh());
    try session.updateMcpSelection(&selectors, .fresh);
    try std.testing.expectEqual(@as(u64, 2), session.catalog_generation);
    try std.testing.expectEqualStrings(old_model_name, session.mcp_selection.?.entries[0].model_name);
    try std.testing.expect(!std.mem.eql(
        u8,
        &old_identity.binding,
        &session.mcp_selection.?.entries[0].permissionIdentity().binding,
    ));
    try std.testing.expectEqual(@as(usize, 0), session.permission_state.ruleCount());
    try std.testing.expectEqual(@as(u32, 1), session.invalidated_mcp_bindings);
    try std.testing.expectEqual(session_authority.RestoreHealth.degraded, session.restore_health);
    var changed_run_view = (try session.materializeMcpRunView()).?;
    defer changed_run_view.deinit();
    try std.testing.expect(changed_run_view.validatesInvocation(
        old_model_name,
        "{\"country\":\"France\"}",
    ));
    try std.testing.expect(changed_run_view.validatesInvocation(
        old_model_name,
        "{\"city\":\"Paris\"}",
    ));

    // A newer Runtime generation is built off-side. If its durable MCP +
    // Permission replacement cannot fit, the Session keeps generation 2,
    // its old immutable view/root, and its exact usage.
    const before_root = session.policy_root;
    const before_usage = try session.measureDurableUsage();
    const minimum_reserve: u64 = 64 + 64 + 128;
    const tight_profile = session_budget.Profile{
        .hard_bytes = before_usage.total_bytes + minimum_reserve,
        .soft_bytes = before_usage.total_bytes + minimum_reserve - 1,
        .input_cap_bytes = 64,
        .provider_request_cap_bytes = 64,
        .provider_result_cap_bytes = 64,
        .tool_result_cap_bytes = 32,
        .mcp_result_cap_bytes = 32,
        .audit_reserve_bytes = 64,
        .terminal_reserve_bytes = 128,
    };
    session.budget_state = try session_budget.SessionState.init(tight_profile);
    try session.budget_state.updateUsage(before_usage.total_bytes);
    server.tool_name = "weather_forecast_extended";
    try std.testing.expectEqual(@as(u64, 3), try runtime.mcp_manager.?.refresh());
    const larger_selectors = [_]mcp_session.Selector{.{
        .server_binding_identity = binding,
        .tool_name = "weather_forecast_extended",
    }};
    try std.testing.expectError(
        error.CheckpointBudgetRequired,
        session.updateMcpSelection(&larger_selectors, .fresh),
    );
    try std.testing.expectEqual(@as(u64, 2), session.catalog_generation);
    try std.testing.expect(session.policy_root == before_root);
    try std.testing.expectEqual(@as(usize, 0), session.permission_state.ruleCount());
    try std.testing.expectEqual(
        before_usage.total_bytes,
        session.budget_state.durable_usage_bytes,
    );
    try std.testing.expectEqual(
        session_budget.Outcome.budget_required,
        session.budget_state.last_outcome,
    );
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
    var calendar_server = fixture.Server{ .tool_name = "events" };
    const binding = [_]u8{0x76} ** 32;
    const calendar_binding = [_]u8{0x78} ** 32;
    const specs = [_]mcp_catalog.ServerSpec{
        .{
            .binding = binding,
            .namespace = "weather",
            .connector = server.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
        .{
            .binding = calendar_binding,
            .namespace = "calendar",
            .connector = calendar_server.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
    };
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
    const original_entry = &original.mcp_selection.?.entries[0];
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
    const expected_permission_binding = original_entry.permissionIdentity().binding;
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
        .mcp_selectors = &selectors,
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
    // The current Runtime exposes additional MCP authority, but restore
    // reconstructs only the checkpoint selection and never auto-enables it.
    try std.testing.expectEqual(@as(usize, 1), restored.session.mcp_selection.?.entries.len);
    try std.testing.expect(
        restored.session.mcp_selection.?.findCanonicalTool(
            &calendar_binding,
            "events",
        ) == null,
    );
    try std.testing.expectEqualStrings(
        expected_model_name,
        restored.session.mcp_selection.?.entries[0].model_name,
    );
    try std.testing.expectEqual(
        session_permission.Decision.allow,
        (try restored.session.permission_state.decide(
            restored.session.mcp_selection.?.entries[0].permissionIdentity(),
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
    try std.testing.expectEqual(@as(usize, 0), changed.session.mcp_selection.?.entries.len);
    try std.testing.expectEqual(@as(usize, 1), changed.session.core_session.conversation.len());
    try std.testing.expectEqual(@as(usize, 2), changed.report.issues.len);
    var saw_permission_issue = false;
    var saw_mcp_issue = false;
    for (changed.report.issues) |issue| switch (issue.subsystem) {
        .permission => {
            saw_permission_issue = true;
            try std.testing.expectEqual(
                session_authority.AuthorityIssueReason.unavailable,
                issue.reason,
            );
            try std.testing.expectEqualStrings("weather", issue.canonical_name);
            try std.testing.expectEqualSlices(
                u8,
                &expected_permission_binding,
                &issue.authority_binding,
            );
        },
        .mcp => {
            saw_mcp_issue = true;
            try std.testing.expectEqual(
                session_authority.AuthorityIssueReason.schema_changed,
                issue.reason,
            );
            try std.testing.expectEqualStrings("weather", issue.canonical_name);
            try std.testing.expectEqualSlices(
                u8,
                &binding,
                &issue.server_binding_identity,
            );
        },
        .skill => return error.TestUnexpectedResult,
    };
    try std.testing.expect(saw_permission_issue and saw_mcp_issue);
    var changed_description = try changed.session.describe(std.testing.allocator);
    defer changed_description.deinit();
    try std.testing.expectEqual(@as(usize, 2), changed_description.authority_issues.len);
    try std.testing.expectEqualSlices(
        u8,
        &changed.report.issues[0].issue_id,
        &changed_description.authority_issues[0].issue_id,
    );
    try std.testing.expectEqual(@as(usize, 0), changed_description.mcp_tools.len);
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

test "RunState observation capacity does not poison the admitted run" {
    var fake = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
        .run_state_projector = run_state.Projector.init(std.testing.allocator),
    };
    defer fake.run_state_projector.deinit();

    for (0..run_state.MAX_IN_FLIGHT_TOOLS + 1) |index| {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "tool-{d}", .{index}) catch unreachable;
        try std.testing.expect(fake.observeRunState(.single, 1, .{ .tool_start = .{
            .id = id,
            .name = "Read",
            .input = "{}",
        } }));
    }
    try std.testing.expect(fake.run_state_observation_disabled);
    try std.testing.expectEqual(wire.STATUS_OK, fake.callback_status.load(.acquire));

    try std.testing.expect(fake.startRunState(.single, 2));
    try std.testing.expect(!fake.run_state_observation_disabled);
    try std.testing.expect(fake.observeRunState(.single, 2, .{ .retry_notice = .{
        .attempt = 1,
        .max = 2,
        .delay_ms = 0,
    } }));
    try std.testing.expectEqual(public_protocol.RunStatePhase.retrying, fake.run_state_projector.phase);
    try std.testing.expect(fake.observeRunState(.single, 2, .stream_begin));
    try std.testing.expectEqual(public_protocol.RunStatePhase.generating, fake.run_state_projector.phase);
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
    const initial_usage = try session.measureDurableUsage();
    const checkpoint_hard = @max(initial_usage.total_bytes + 1024, 8192);
    const checkpoint_profile = session_budget.Profile{
        .hard_bytes = checkpoint_hard,
        .soft_bytes = checkpoint_hard - 1,
        .input_cap_bytes = 1024,
        .provider_request_cap_bytes = 1024,
        .provider_result_cap_bytes = 512,
        .tool_result_cap_bytes = 256,
        .mcp_result_cap_bytes = 256,
        .audit_reserve_bytes = 64,
        .terminal_reserve_bytes = 128,
    };
    session.budget_state = try session_budget.SessionState.init(checkpoint_profile);
    try session.budget_state.updateUsage(initial_usage.total_bytes);
    var capture = CaptureSink{ .allocator = std.testing.allocator };
    defer capture.deinit();
    const limits = session_checkpoint.Limits{
        .hard_bytes = 1024 * 1024,
        .chunk_bytes = 17,
    };

    const first = try session.exportCheckpoint(limits, capture.sink());
    try std.testing.expectEqual(@as(u64, 1), session.checkpoint_generation);
    try std.testing.expectEqual(first.total_bytes, capture.bytes.items.len);
    try std.testing.expect(first.total_bytes <= checkpoint_profile.hard_bytes);
    try std.testing.expectEqual(
        first.total_bytes,
        session.budget_state.durable_usage_bytes,
    );
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

    // The facade may become poisoned after Core has returned to an otherwise
    // inspectable idle state. describe() is the Host's health surface, so it
    // must expose that terminal facade state instead of reporting a healthy
    // idle Session.
    session.facade_poisoned.store(true, .release);
    var poisoned_description = try session.describe(std.testing.allocator);
    defer poisoned_description.deinit();
    try std.testing.expectEqual(
        session_authority.Lifecycle.poisoned,
        poisoned_description.lifecycle,
    );
    session.facade_poisoned.store(false, .release);

    capture.clear();
    capture.fail = true;
    const usage_before_sink_failure = session.budget_state.durable_usage_bytes;
    try std.testing.expectError(
        error.SinkFailed,
        session.exportCheckpoint(limits, capture.sink()),
    );
    try std.testing.expectEqual(@as(u64, 1), session.checkpoint_generation);
    try std.testing.expectEqual(
        usage_before_sink_failure,
        session.budget_state.durable_usage_bytes,
    );
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
    const exported = try original_facade.exportCheckpoint(
        limits,
        checkpoint.sink(),
    );
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
        exported.total_bytes,
        restored.session.budget_state.durable_usage_bytes,
    );
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
    try std.testing.expectEqual(
        exported.total_bytes,
        description.budget.durable_usage_bytes,
    );

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

test "Revision 9 AgentCore restore uses execution identity and degrades unavailable or changed Skill authority" {
    const record = skill_catalog.SkillRecord{
        .skill_id = [_]u8{'0'} ** 64,
        .execution_id = [_]u8{'1'} ** 64,
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
    try std.testing.expect(!std.mem.eql(
        u8,
        &record.skill_id,
        &record.execution_id,
    ));
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
        .content_bytes = 0,
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
    const all_enabled = skill_availability.Spec{
        .default_state = .enabled,
        .exceptions = &.{},
    };
    var matching_cell = skill_catalog_handles.CatalogCell{
        .runtime = &runtime.catalogs,
        .snapshot = &snapshot,
        .references = 1,
        .accounted_bytes = 0,
    };
    var matching_binding: ?SkillBinding = .{
        .cell = &matching_cell,
        .selection = try skill_availability.Selection.init(
            std.testing.allocator,
            &snapshot,
            all_enabled,
        ),
    };
    const matching = try restoreCheckpoint(
        &runtime,
        base_config,
        &matching_binding,
        checkpoint.source(),
        limits,
    );
    try std.testing.expect(matching_binding == null);
    try std.testing.expectEqual(
        session_authority.RestoreHealth.complete,
        matching.report.health,
    );
    try std.testing.expectEqual(
        session_authority.SkillDisposition.restored,
        matching.report.skill.disposition,
    );
    try std.testing.expectEqual(@as(u32, 1), matching.report.skill.restored_enabled);
    try std.testing.expectEqual(@as(u32, 0), matching.report.skill.invalidated);
    try std.testing.expectEqual(@as(usize, 0), matching.report.issues.len);
    try std.testing.expect(matching.session.skill_binding != null);
    matching.session.skill_binding.?.selection.deinit();
    matching.session.skill_binding = null;
    var matching_diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        sessionDestroy(matching.session.handle(), &matching_diagnostic),
    );
    bufferRelease(&matching_diagnostic);

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
    try std.testing.expectEqual(@as(usize, 1), unavailable.report.issues.len);
    try std.testing.expectEqual(
        session_authority.AuthoritySubsystem.skill,
        unavailable.report.issues[0].subsystem,
    );
    try std.testing.expectEqual(
        session_authority.AuthorityIssueReason.unavailable,
        unavailable.report.issues[0].reason,
    );
    try std.testing.expectEqualSlices(
        u8,
        &record.execution_id,
        &unavailable.report.issues[0].skill_id,
    );
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
    try std.testing.expectEqual(@as(usize, 1), changed.report.issues.len);
    try std.testing.expectEqual(
        session_authority.AuthorityIssueReason.identity_changed,
        changed.report.issues[0].reason,
    );
    try std.testing.expect(!std.mem.allEqual(
        u8,
        &changed.report.issues[0].issue_id,
        0,
    ));
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
    const current_mcp_selection = [_]mcp_session.Selector{.{
        .server_binding_identity = persisted_entries[0].server_binding_identity,
        .tool_name = persisted_entries[0].tool_name,
    }};
    const restore_config = RestoreHostConfig{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .provider_kind = .anthropic,
        .api_key = "current-key",
        .base_url = null,
        .permission_mode = .default,
        .permission_rules = null,
        .workspace = .{ .root = cwd, .home = cwd },
        .allowed_tools = &.{},
        .mcp_selectors = &current_mcp_selection,
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
    try std.testing.expect(first.session.mcp_selection == null);
    try std.testing.expectEqual(@as(u64, 0), first.report.catalog_generation);
    try std.testing.expectEqual(@as(usize, 1), first.session.core_session.conversation.len());
    try std.testing.expectEqualStrings(
        "survives unavailable MCP server",
        first.session.core_session.conversation.messages.items[0].blocks[0].text,
    );
    try std.testing.expectEqual(@as(usize, 2), first.report.issues.len);
    try std.testing.expectEqual(
        session_authority.AuthoritySubsystem.permission,
        first.report.issues[0].subsystem,
    );
    try std.testing.expectEqual(
        session_authority.AuthoritySubsystem.mcp,
        first.report.issues[1].subsystem,
    );
    try std.testing.expectEqual(
        session_authority.AuthorityIssueReason.unavailable,
        first.report.issues[1].reason,
    );
    try std.testing.expectEqualSlices(
        u8,
        &persisted_entries[0].server_binding_identity,
        &first.report.issues[1].server_binding_identity,
    );
    var first_description = try first.session.describe(std.testing.allocator);
    defer first_description.deinit();
    try std.testing.expectEqual(@as(usize, 2), first_description.authority_issues.len);
    try std.testing.expectEqualSlices(
        u8,
        &first.report.issues[1].issue_id,
        &first_description.authority_issues[1].issue_id,
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

test "ABI Runtime accepts Session-owned WebSearch and WebFetch built-ins" {
    const names = [_]wire.BytesViewV1{ view("WebSearch"), view("WebFetch") };
    var config = std.mem.zeroes(wire.RuntimeConfigV1);
    config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    config.builtin_tools = &names;
    config.builtin_tool_count = names.len;
    var runtime: ?*wire.RuntimeHandle = null;
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer bufferRelease(&diagnostic);

    try std.testing.expectEqual(wire.STATUS_OK, runtimeCreate(&config, &runtime, &diagnostic));
    try std.testing.expect(runtime != null);
    try std.testing.expectEqual(wire.STATUS_OK, runtimeDestroy(runtime, &diagnostic));
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

    // A valid replacement must also remain fully off-side when the durable
    // Session budget cannot reserve the post-mutation checkpoint plus the
    // minimum next-Run terminal space.
    const before_budget_rejection = try session.measureDurableUsage();
    const permission_profile = session_budget.Profile{
        .hard_bytes = before_budget_rejection.total_bytes,
        .soft_bytes = before_budget_rejection.total_bytes - 1,
        .input_cap_bytes = 64,
        .provider_request_cap_bytes = 64,
        .provider_result_cap_bytes = 64,
        .tool_result_cap_bytes = 32,
        .mcp_result_cap_bytes = 32,
        .audit_reserve_bytes = 64,
        .terminal_reserve_bytes = 128,
    };
    session.budget_state = try session_budget.SessionState.init(permission_profile);
    try session.budget_state.updateUsage(before_budget_rejection.total_bytes);
    try std.testing.expectError(
        error.CheckpointBudgetRequired,
        session.updatePermissionRules(.{ .allow = &.{"Read"} }),
    );
    try std.testing.expect(native_session.permission_ctx.settings == published);
    try std.testing.expectEqual(published_generation, session.policy_generation);
    try std.testing.expectEqual(@as(usize, 1), session.permission_state.ruleCount());
    try std.testing.expect(std.mem.eql(
        u8,
        &published_fingerprint,
        &session.policy_fingerprint,
    ));
    try std.testing.expectEqual(
        before_budget_rejection.total_bytes,
        session.budget_state.durable_usage_bytes,
    );
    try std.testing.expectEqual(
        session_budget.Outcome.budget_required,
        session.budget_state.last_outcome,
    );

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

    const native_runtime = try core.agent_session.AgentRuntime.create(
        std.testing.allocator,
        .{ .builtin_tools = &.{} },
    );
    defer native_runtime.destroy() catch unreachable;
    const native_session = try native_runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{
            .root = workspace.root,
            .home = workspace.home,
            .shell = .disabled,
        },
        .allowed_tools = &.{},
    });
    defer native_session.destroy() catch unreachable;

    var runtime = AbiRuntime{
        .core_runtime = native_runtime,
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
        .core_session = native_session,
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

    const skill_state_before = try session_authority.encodeSkillState(
        std.testing.allocator,
        session.skill_binding.?.snapshot(),
        &session.skill_binding.?.selection,
    );
    defer std.testing.allocator.free(skill_state_before);
    const before_skill_budget_rejection = try session.measureDurableUsage();
    const skill_profile = session_budget.Profile{
        .hard_bytes = before_skill_budget_rejection.total_bytes + 255,
        .soft_bytes = before_skill_budget_rejection.total_bytes + 254,
        .input_cap_bytes = 64,
        .provider_request_cap_bytes = 64,
        .provider_result_cap_bytes = 64,
        .tool_result_cap_bytes = 32,
        .mcp_result_cap_bytes = 32,
        .audit_reserve_bytes = 64,
        .terminal_reserve_bytes = 128,
    };
    session.budget_state = try session_budget.SessionState.init(skill_profile);
    try session.budget_state.updateUsage(before_skill_budget_rejection.total_bytes);
    try std.testing.expectError(
        error.CheckpointBudgetRequired,
        session.updateSkills(null, .{
            .default_state = .disabled,
            .exceptions = &.{},
        }),
    );
    const skill_state_after = try session_authority.encodeSkillState(
        std.testing.allocator,
        session.skill_binding.?.snapshot(),
        &session.skill_binding.?.selection,
    );
    defer std.testing.allocator.free(skill_state_after);
    try std.testing.expectEqualSlices(u8, skill_state_before, skill_state_after);
    try std.testing.expect(session.skill_binding.?.cell == first_cell);
    try std.testing.expectEqual(@as(usize, 1), first_cell.references);
    try std.testing.expectEqual(
        before_skill_budget_rejection.total_bytes,
        session.budget_state.durable_usage_bytes,
    );
    try std.testing.expectEqual(
        session_budget.Outcome.budget_required,
        session.budget_state.last_outcome,
    );

    session.budget_state = try session_budget.SessionState.init(.{});
    try session.budget_state.updateUsage(before_skill_budget_rejection.total_bytes);

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
        .execution_id = [_]u8{'e'} ** 64,
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
        .content_bytes = 0,
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
        &record.execution_id,
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

    session.skill_binding.?.selection.deinit();
    session.skill_binding.?.selection = try skill_availability.Selection.init(
        std.testing.allocator,
        &snapshot,
        .{ .default_state = .enabled, .exceptions = &.{} },
    );
    session.budget_state = try session_budget.SessionState.init(.{
        .input_cap_bytes = 128,
    });
    try std.testing.expectError(error.CheckpointBudgetRequired, session.runSkill(
        &materializations,
        1,
        &snapshot.revision,
        &record.execution_id,
        "{\"values\":[]}",
        1,
    ));
    try std.testing.expectEqual(@as(u64, 0), native_session.last_run_id);
    try std.testing.expectEqual(initial_messages, native_session.conversation.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), materializations.active_count);
}

test "checkpoint budget rejects text before consuming run identity" {
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
    const profile = session_budget.Profile{
        .hard_bytes = 4096,
        .soft_bytes = 3072,
        .input_cap_bytes = 1024,
        .provider_request_cap_bytes = 1024,
        .provider_result_cap_bytes = 512,
        .tool_result_cap_bytes = 256,
        .mcp_result_cap_bytes = 256,
        .audit_reserve_bytes = 64,
        .terminal_reserve_bytes = 128,
    };
    var facade = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = native_session,
        .budget_state = try session_budget.SessionState.init(profile),
    };
    var materializations = try skill_materialization.Manager.init(
        std.testing.allocator,
    );
    defer materializations.deinit() catch unreachable;
    var oversized: [1025]u8 = undefined;
    @memset(&oversized, 'x');
    const before_messages = native_session.conversation.messages.items.len;
    var before = try native_session.snapshotCommitted();
    const before_run_id = before.last_run_id;
    before.deinit();

    try std.testing.expectError(
        error.CheckpointBudgetRequired,
        facade.runTextWithBoundSkills(
            &materializations,
            1,
            &oversized,
            1,
        ),
    );

    var after = try native_session.snapshotCommitted();
    defer after.deinit();
    try std.testing.expectEqual(before_run_id, after.last_run_id);
    try std.testing.expectEqual(
        before_messages,
        native_session.conversation.messages.items.len,
    );
    try std.testing.expectEqual(
        session_budget.Outcome.budget_required,
        facade.budget_state.last_outcome,
    );
}

test "budgeted Run completes with an active background job" {
    // Regression invariant: Run finalization may measure durable state while a
    // runtime job exists; the checkpoint export eligibility contract remains
    // enforced by snapshotCommitted() on the explicit export path.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const cwd = root_buffer[0..root_len];
    const native_runtime = try core.agent_session.AgentRuntime.create(
        std.testing.allocator,
        .{ .builtin_tools = &.{"Bash"} },
    );
    defer native_runtime.destroy() catch unreachable;
    const native_session = try native_runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .workspace = .{ .root = cwd, .shell = .unrestricted },
        .allowed_tools = &.{"Bash"},
    });
    defer native_session.destroy() catch unreachable;
    const active_job = try native_session.jobs.?.spawnBackground(test_long_running_command, cwd);
    native_session.jobs.?.reapExited();
    try std.testing.expectEqual(
        process.ReapStatus.running,
        process.reapNonblock(native_session.jobs.?.get(active_job.idSlice()).?.proc),
    );
    try std.testing.expectEqual(
        core.job_registry.JobStatus.running,
        native_session.jobs.?.get(active_job.idSlice()).?.status,
    );

    var facade = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = native_session,
        .budget_state = try session_budget.SessionState.init(.{
            .hard_bytes = 1 << 20,
            .soft_bytes = (1 << 20) - 1,
            .input_cap_bytes = 4096,
            .provider_request_cap_bytes = 64 * 1024,
            .provider_result_cap_bytes = 4096,
            .tool_result_cap_bytes = 4096,
            .mcp_result_cap_bytes = 4096,
            .audit_reserve_bytes = 64,
            .terminal_reserve_bytes = 128,
        }),
    };
    var test_provider = CompactBudgetTestProvider{
        .allocator = std.testing.allocator,
        .payload_bytes = 0,
    };
    const prompt = "complete while server runs";
    const preflight = try facade.preflightRootRecords(&.{prompt});
    var controller = session_budget.Controller.init(
        std.testing.allocator,
        facade.budget_state.profile,
        preflight,
    );
    var budget_provider = session_budget.BudgetedProvider{
        .allocator = std.testing.allocator,
        .controller = &controller,
        .base = test_provider.provider(),
    };
    var admitted = try native_session.admitRun(
        1,
        .{ .ctx = &facade, .emit = AbiSession.emit },
    );
    const surface = core.agent_session.RunToolSurface{
        .definitions = native_session.tools.definitions,
        .dispatcher = native_session.tools.dispatcher(),
    };
    var budget_tools = session_budget.ToolEnvironment{
        .controller = &controller,
        .base = surface,
    };
    const result = try admitted.runUserMessagesWithToolSurfaceUsingProvider(
        &.{prompt},
        1,
        null,
        budget_tools.surface(),
        budget_provider.provider(),
    );
    _ = try facade.finishBudgetedRun(1, &controller);
    try std.testing.expect(result.stop_reason == .end_turn);
    try std.testing.expect(!facade.facade_poisoned.load(.acquire));
    try std.testing.expect(facade.budget_state.durable_usage_bytes != 0);
}

test "Permission Session grant reserves durable bytes before publication" {
    const profile = session_budget.Profile{
        .hard_bytes = 4096,
        .soft_bytes = 3072,
        .input_cap_bytes = 1024,
        .provider_request_cap_bytes = 1024,
        .provider_result_cap_bytes = 512,
        .tool_result_cap_bytes = 256,
        .mcp_result_cap_bytes = 256,
        .audit_reserve_bytes = 128,
        .terminal_reserve_bytes = 128,
    };
    try profile.validate();
    const digest = try session_permission.digestCanonicalArguments(
        std.testing.allocator,
        "{\"command\":\"echo ok\"}",
        .{},
    );
    const candidate = (try session_permission.deriveRuleCandidate(.{
        .namespace = .builtin,
        .name = "Bash",
    }, digest)).?;
    var facade = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
        .permission_state = try session_permission.State.init(
            std.testing.allocator,
            1,
        ),
    };
    defer facade.permission_state.deinit();

    var denied = session_budget.Controller.init(std.testing.allocator, profile, .{
        .input_delta_bytes = 0,
        .projected_usage_bytes = 3900,
        .minimum_required_bytes = 3900,
    });
    facade.active_budget_controller = &denied;
    try std.testing.expectError(
        error.BudgetExhausted,
        facade.rememberPermissionResponseBudgeted(.allow_session, candidate),
    );
    try std.testing.expectEqual(@as(usize, 0), facade.permission_state.ruleCount());
    try std.testing.expectEqual(session_budget.Outcome.budget_exhausted, denied.outcome());
    try std.testing.expectEqual(@as(u64, 0), denied.reserved_bytes);

    var admitted = session_budget.Controller.init(std.testing.allocator, profile, .{
        .input_delta_bytes = 0,
        .projected_usage_bytes = 1000,
        .minimum_required_bytes = 1000,
    });
    facade.active_budget_controller = &admitted;
    try std.testing.expectEqual(
        session_permission.RememberResult.added,
        try facade.rememberPermissionResponseBudgeted(.allow_session, candidate),
    );
    try std.testing.expectEqual(@as(usize, 1), facade.permission_state.ruleCount());
    try std.testing.expectEqual(@as(u64, 0), admitted.reserved_bytes);
    try std.testing.expectEqual(
        session_permission.RememberResult.already_present,
        try facade.rememberPermissionResponseBudgeted(.allow_session, candidate),
    );
    try std.testing.expectEqual(@as(u64, 0), admitted.reserved_bytes);
    facade.active_budget_controller = null;
}

test "durable mutation is rejected before model publication" {
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
    var facade = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = native_session,
    };
    const initial = try facade.measureDurableUsage();
    const profile = session_budget.Profile{
        .hard_bytes = initial.total_bytes + 216,
        .soft_bytes = initial.total_bytes + 215,
        .input_cap_bytes = 64,
        .provider_request_cap_bytes = 64,
        .provider_result_cap_bytes = 64,
        .tool_result_cap_bytes = 32,
        .mcp_result_cap_bytes = 32,
        .audit_reserve_bytes = 16,
        .terminal_reserve_bytes = 128,
    };
    facade.budget_state = try session_budget.SessionState.init(profile);
    try facade.budget_state.updateUsage(initial.total_bytes);
    var larger_model: [64]u8 = undefined;
    @memset(&larger_model, 'm');

    try std.testing.expectError(
        error.CheckpointBudgetRequired,
        facade.setModel(&larger_model),
    );
    try std.testing.expectEqualStrings("test-model", native_session.model);
    try std.testing.expectEqual(AbiSession.CallState.idle, facade.call_state);
    try std.testing.expectEqual(
        session_budget.Outcome.budget_required,
        facade.budget_state.last_outcome,
    );
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer bufferRelease(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_BUDGET_REQUIRED,
        sessionSetModel(facade.handle(), view(&larger_model), &diagnostic),
    );
    try std.testing.expectEqualStrings("test-model", native_session.model);
    try std.testing.expectEqual(AbiSession.CallState.idle, facade.call_state);
}

test "compact bounds Provider payload and preserves checkpointability" {
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
    try native_session.conversation.appendText(.user, "old context one");
    try native_session.conversation.appendText(.assistant, "old context two");
    try native_session.conversation.appendText(.user, "recent context");
    // Default compact keeps the newest ten messages. Seed enough durable
    // history to force the summarization Provider path instead of exercising
    // the legitimate no-change fast path.
    for (0..8) |index| {
        const message = try std.fmt.allocPrint(
            std.testing.allocator,
            "compact budget source message {d}",
            .{index},
        );
        defer std.testing.allocator.free(message);
        try native_session.conversation.appendText(
            if (index % 2 == 0) .assistant else .user,
            message,
        );
    }
    var runtime = AbiRuntime{
        .core_runtime = native_runtime,
        .host_tools = &.{},
        .catalogs = skill_catalog_handles.RuntimeCatalogs.initWithSecret(
            std.testing.allocator,
            [_]u8{0x95} ** 32,
        ),
        .materializations = undefined,
    };
    defer {
        runtime.catalogs.tryBeginDestroy() catch unreachable;
        runtime.catalogs.finishDestroy();
    }
    var facade = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = native_session,
        .runtime = &runtime,
    };
    const initial = try facade.measureDurableUsage();
    const hard = @max(initial.total_bytes + 4096, 8192);
    const profile = session_budget.Profile{
        .hard_bytes = hard,
        .soft_bytes = hard - 1,
        .input_cap_bytes = 1024,
        .provider_request_cap_bytes = 4096,
        .provider_result_cap_bytes = 64,
        .tool_result_cap_bytes = 32,
        .mcp_result_cap_bytes = 32,
        .audit_reserve_bytes = 64,
        .terminal_reserve_bytes = 128,
    };
    facade.budget_state = try session_budget.SessionState.init(profile);
    try facade.budget_state.updateUsage(initial.total_bytes);
    var test_provider = CompactBudgetTestProvider{
        // Provider-owned stream events follow the AgentCore Session allocator
        // contract because the consumer releases them after projection.
        .allocator = allocator,
        .payload_bytes = 512,
    };

    const before_compact_messages = native_session.conversation.len();
    const report = try facade.compactBudgetedUsingProvider(
        1,
        test_provider.provider(),
    );
    try std.testing.expectEqual(@as(u32, 1), test_provider.calls);
    try std.testing.expectEqual(
        core.compact_kernel.Outcome.aborted,
        report.outcome,
    );
    try std.testing.expectEqual(
        session_budget.Outcome.resource_limit,
        facade.budget_state.last_outcome,
    );
    try std.testing.expect(!facade.facade_poisoned.load(.acquire));
    try std.testing.expect(facade.budget_state.durable_usage_bytes <= hard);
    try std.testing.expectEqual(
        before_compact_messages,
        native_session.conversation.len(),
    );
    try std.testing.expectEqualStrings(
        "old context one",
        native_session.conversation.messages.items[0].blocks[0].text,
    );
    for (native_session.conversation.messages.items) |message| {
        for (message.blocks) |block| switch (block) {
            .text => |text_block| try std.testing.expect(
                std.mem.indexOf(u8, text_block, "ssssssss") == null,
            ),
            else => {},
        };
    }
    var checkpoint = TestCheckpointBuffer{
        .allocator = std.testing.allocator,
    };
    defer checkpoint.deinit();
    _ = try facade.exportCheckpoint(profile.checkpointLimits(), checkpoint.sink());
    var decoded = try session_checkpoint.decodeFromSource(
        std.testing.allocator,
        checkpoint.source(),
        profile.checkpointLimits(),
    );
    decoded.deinit();
}

test "near-hard durable state can compact as a replacement transaction" {
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
    var runtime = AbiRuntime{
        .core_runtime = native_runtime,
        .host_tools = &.{},
        .catalogs = skill_catalog_handles.RuntimeCatalogs.initWithSecret(
            std.testing.allocator,
            [_]u8{0x99} ** 32,
        ),
        .materializations = undefined,
    };
    defer {
        runtime.catalogs.tryBeginDestroy() catch unreachable;
        runtime.catalogs.finishDestroy();
    }
    var message_bytes: [512]u8 = undefined;
    for (0..20) |index| {
        @memset(&message_bytes, @as(u8, 'a') + @as(u8, @intCast(index % 20)));
        try native_session.conversation.appendText(
            if (index % 2 == 0) .user else .assistant,
            &message_bytes,
        );
    }
    var facade = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = native_session,
        .runtime = &runtime,
    };
    const initial = try facade.measureDurableUsage();
    const hard = initial.total_bytes + 255;
    const profile = session_budget.Profile{
        .hard_bytes = hard,
        .soft_bytes = hard - 1,
        .input_cap_bytes = 1024,
        .provider_request_cap_bytes = initial.total_bytes - 1,
        .provider_result_cap_bytes = 64,
        .tool_result_cap_bytes = 256,
        .mcp_result_cap_bytes = 256,
        .audit_reserve_bytes = 64,
        .terminal_reserve_bytes = 128,
    };
    try profile.validate();
    try std.testing.expect(
        initial.total_bytes + try profile.minimumRunReserve() > hard,
    );
    facade.budget_state = try session_budget.SessionState.init(profile);
    try facade.budget_state.updateUsage(initial.total_bytes);
    var test_provider = CompactBudgetTestProvider{
        .allocator = std.testing.allocator,
        .payload_bytes = 64,
    };

    const report = try facade.compactBudgetedUsingProvider(
        1,
        test_provider.provider(),
    );
    try std.testing.expectEqual(
        session_budget.Outcome.none,
        facade.budget_state.last_outcome,
    );
    try std.testing.expectEqual(core.compact_kernel.Outcome.compacted, report.outcome);
    try std.testing.expectEqual(@as(u32, 1), test_provider.calls);
    try std.testing.expect(!facade.facade_poisoned.load(.acquire));
    try std.testing.expect(facade.budget_state.durable_usage_bytes < initial.total_bytes);

    var checkpoint = TestCheckpointBuffer{ .allocator = std.testing.allocator };
    defer checkpoint.deinit();
    const exported = try facade.exportCheckpoint(
        profile.checkpointLimits(),
        checkpoint.sink(),
    );
    try std.testing.expect(exported.total_bytes <= hard);
}

test "admitted resource limit remains bounded and checkpointable" {
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
    var runtime = AbiRuntime{
        .core_runtime = native_runtime,
        .host_tools = &.{},
        .catalogs = skill_catalog_handles.RuntimeCatalogs.initWithSecret(
            std.testing.allocator,
            [_]u8{0x91} ** 32,
        ),
        .materializations = undefined,
    };
    defer {
        runtime.catalogs.tryBeginDestroy() catch unreachable;
        runtime.catalogs.finishDestroy();
    }
    const profile = session_budget.Profile{
        .hard_bytes = 8192,
        .soft_bytes = 6144,
        .input_cap_bytes = 1024,
        .provider_request_cap_bytes = 1024,
        .provider_result_cap_bytes = 512,
        .tool_result_cap_bytes = 256,
        .mcp_result_cap_bytes = 256,
        .audit_reserve_bytes = 64,
        .terminal_reserve_bytes = 128,
    };
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
        .budget_profile = profile,
    });
    defer {
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        const status = sessionDestroy(session.handle(), &diagnostic);
        bufferRelease(&diagnostic);
        std.debug.assert(status == wire.STATUS_OK);
    }

    const preflight = try session.preflightRootRecords(&.{"accepted"});
    var controller = session_budget.Controller.init(
        std.testing.allocator,
        profile,
        preflight,
    );
    var reservation = try controller.beginOperation(.provider, 1);
    reservation.failResourceLimit(513);
    var sink_ctx: u8 = 0;
    var admitted = try session.core_session.admitRun(
        1,
        TestEventSink.sink(&sink_ctx),
    );
    _ = try admitted.finishWithoutConversation();
    try std.testing.expectEqual(
        session_budget.Outcome.resource_limit,
        try session.finishBudgetedRun(1, &controller),
    );

    var checkpoint = TestCheckpointBuffer{
        .allocator = std.testing.allocator,
    };
    defer checkpoint.deinit();
    const report = try session.exportCheckpoint(
        profile.checkpointLimits(),
        checkpoint.sink(),
    );
    try std.testing.expect(report.total_bytes <= profile.hard_bytes);
    var decoded = try session_checkpoint.decodeFromSource(
        std.testing.allocator,
        checkpoint.source(),
        profile.checkpointLimits(),
    );
    defer decoded.deinit();
    try std.testing.expectEqual(
        session_checkpoint.TerminalKind.resource_limit,
        decoded.descriptor.terminal_kind,
    );
    try std.testing.expectEqual(@as(u64, 1), decoded.descriptor.terminal_id);
    const last = decoded.conversation.messages.items[
        decoded.conversation.messages.items.len - 1
    ];
    try std.testing.expectEqual(core.message.Role.assistant, last.role);
    try std.testing.expectEqualStrings(
        session_budget.RESOURCE_LIMIT_MARKER,
        last.blocks[0].text,
    );
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
        .execution_id = [_]u8{'e'} ** 64,
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
        .content_bytes = 0,
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
        .execution_id = [_]u8{'b'} ** 64,
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
        .content_bytes = 0,
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
