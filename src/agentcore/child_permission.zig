//! AgentCore-only Permission scope for synchronous fork children.
//!
//! A fork child belongs to the same logical Session and therefore evaluates
//! the same canonical rules and Session grants. It does not, however, own a
//! resumable Host-UI boundary. The derived context consequently preserves the
//! parent's authority ceiling while removing UI authority and turning an
//! explicit `ask` result into a local deny. The owner callbacks keep
//! AgentCore's pending-request and child tool-call provenance state out of the
//! shared Core/subagent implementation.

const std = @import("std");
const core = @import("metacodes-core");
const event_projection = @import("event_projection.zig");

const PermissionContext = core.permission.PermissionContext;
const DecisionOverride = core.permission.PermissionDecisionOverride;
const ImportedDecision = core.permission.ImportedPermissionDecision;
const PermissionResult = core.permission.PermissionResult;

pub const Owner = struct {
    parent: *const PermissionContext,
    ctx: *anyopaque,
    swap_trace_fn: *const fn (
        ctx: *anyopaque,
        replacement: ?*event_projection.Projector,
    ) ?*event_projection.Projector,
    clear_pending_fn: *const fn (ctx: *anyopaque) void,

    fn swapTrace(
        self: Owner,
        replacement: ?*event_projection.Projector,
    ) ?*event_projection.Projector {
        return self.swap_trace_fn(self.ctx, replacement);
    }

    fn clearPending(self: Owner) void {
        self.clear_pending_fn(self.ctx);
    }
};

const Adapter = struct {
    owner: Owner,
    delegate: DecisionOverride,

    fn override(self: *Adapter) DecisionOverride {
        return .{ .ctx = self, .decideFn = decide };
    }

    fn decide(
        raw: *anyopaque,
        tool_name: []const u8,
        arguments_json: []const u8,
        imported: ImportedDecision,
    ) ?PermissionResult {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        // A stale pending request from an outer decision must never be
        // interpreted as belonging to this child. The delegate may stage a
        // pending request while computing `ask`; clear it before returning
        // because this scope cannot publish a Host UI request.
        self.owner.clearPending();
        defer self.owner.clearPending();
        const result = self.delegate.decide(
            tool_name,
            arguments_json,
            imported,
        ) orelse return null;
        return if (result == .ask) .deny else result;
    }
};

/// Stack-owned scope. Callers must initialize it at its final address and keep
/// it alive until the synchronous child has quiesced; `permissionContext()`
/// points at storage inside this value.
pub const Lease = struct {
    owner: Owner = undefined,
    previous_trace: ?*event_projection.Projector = null,
    adapter: Adapter = undefined,
    permission_context: PermissionContext = undefined,
    active: bool = false,

    pub fn init(
        self: *Lease,
        owner: Owner,
        projector: *event_projection.Projector,
    ) void {
        std.debug.assert(!self.active);
        self.owner = owner;
        self.previous_trace = owner.swapTrace(projector);
        self.permission_context = owner.parent.scopedDerive(null);
        self.permission_context.ui_requester = null;
        self.permission_context.no_interactive_prompt = true;
        if (owner.parent.decision_override) |delegate| {
            self.adapter = .{ .owner = owner, .delegate = delegate };
            self.permission_context.decision_override = self.adapter.override();
        }
        owner.clearPending();
        self.active = true;
    }

    pub fn deinit(self: *Lease) void {
        if (!self.active) return;
        self.owner.clearPending();
        _ = self.owner.swapTrace(self.previous_trace);
        self.active = false;
    }

    pub fn permissionContext(self: *Lease) *PermissionContext {
        std.debug.assert(self.active);
        return &self.permission_context;
    }
};

test "fork Permission lease preserves authority but cannot publish ask UI" {
    const Probe = struct {
        trace: ?*event_projection.Projector = null,
        clears: usize = 0,
        decisions: usize = 0,

        fn swapTrace(
            raw: *anyopaque,
            replacement: ?*event_projection.Projector,
        ) ?*event_projection.Projector {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const previous = self.trace;
            self.trace = replacement;
            return previous;
        }

        fn clearPending(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.clears += 1;
        }

        fn decide(
            raw: *anyopaque,
            tool_name: []const u8,
            _: []const u8,
            _: ImportedDecision,
        ) ?PermissionResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.decisions += 1;
            return if (std.mem.eql(u8, tool_name, "Read")) .allow else .ask;
        }
    };
    const Sink = struct {
        fn emit(_: *anyopaque, _: core.session_id.SessionId, _: core.protocol.ui_event.CoreEvent) void {}
        fn poll(_: *anyopaque, _: core.session_id.SessionId) ?core.protocol.ui_event.UiEvent {
            return null;
        }
    };

    var marker: u8 = 0;
    const downstream = core.protocol.ui_backend.UiBackend{
        .ctx = &marker,
        .emit = Sink.emit,
        .poll = Sink.poll,
    };
    var projector = event_projection.Projector.init(
        std.testing.allocator,
        .model_tool,
        &downstream,
    );
    defer projector.deinit();
    var probe = Probe{};
    var parent = core.permission.createContext(.default, std.testing.allocator);
    parent.ui_requester = .{
        .ctx = &marker,
        .requestFn = struct {
            fn request(
                _: *anyopaque,
                _: core.session_id.SessionId,
                _: std.mem.Allocator,
                _: *const core.protocol.ui_request.UiRequest,
                _: *core.protocol.ui_request.UiResponse,
            ) anyerror!core.protocol.ui_request.RequestOutcome {
                return .answered;
            }
        }.request,
    };
    parent.no_interactive_prompt = false;
    parent.decision_override = .{ .ctx = &probe, .decideFn = Probe.decide };
    const owner = Owner{
        .parent = &parent,
        .ctx = &probe,
        .swap_trace_fn = Probe.swapTrace,
        .clear_pending_fn = Probe.clearPending,
    };

    var lease = Lease{};
    lease.init(owner, &projector);
    defer lease.deinit();
    const child = lease.permissionContext();
    try std.testing.expect(child.ui_requester == null);
    try std.testing.expect(child.no_interactive_prompt);
    try std.testing.expectEqual(parent.modeValue(), child.modeValue());
    try std.testing.expectEqual(
        PermissionResult.allow,
        core.permission.checkPermission(child, "Read", "{}"),
    );
    try std.testing.expectEqual(
        PermissionResult.deny,
        core.permission.checkPermission(child, "Write", "{}"),
    );
    try std.testing.expectEqual(@as(usize, 2), probe.decisions);
    try std.testing.expect(probe.clears >= 5);
    try std.testing.expect(probe.trace == &projector);
}
