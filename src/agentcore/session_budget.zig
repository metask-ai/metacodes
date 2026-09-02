//! AgentCore-owned durable checkpoint admission and reservation controller.
//!
//! This module is deliberately a run-scoped decorator around the neutral
//! Provider and ToolDispatcher interfaces. It does not teach the shared agent
//! loop AgentCore policy, and it never performs hidden compaction.

const std = @import("std");
const core = @import("metacodes-core");
const sync = @import("platform").sync;
const checkpoint = @import("session_checkpoint.zig");
const mcp_session = @import("mcp_session.zig");

pub const BUDGET_REQUIRED_MARKER =
    "{\"agentcore\":\"checkpoint_budget_required\"}";
pub const BUDGET_EXHAUSTED_MARKER =
    "{\"agentcore\":\"checkpoint_budget_exhausted\"}";
pub const RESOURCE_LIMIT_MARKER =
    "{\"agentcore\":\"checkpoint_payload_resource_limit\",\"side_effect\":\"indeterminate\"}";

pub const DEFAULT_HARD_BYTES: u64 = 64 * 1024 * 1024;
pub const DEFAULT_SOFT_BYTES: u64 = 48 * 1024 * 1024;
pub const DEFAULT_INPUT_CAP_BYTES: u64 = 8 * 1024 * 1024;
pub const DEFAULT_PROVIDER_REQUEST_CAP_BYTES: u64 = 16 * 1024 * 1024;
pub const DEFAULT_PROVIDER_RESULT_CAP_BYTES: u64 = 4 * 1024 * 1024;
pub const DEFAULT_TOOL_RESULT_CAP_BYTES: u64 = 2 * 1024 * 1024;
pub const DEFAULT_MCP_RESULT_CAP_BYTES: u64 = 2 * 1024 * 1024;
pub const DEFAULT_AUDIT_RESERVE_BYTES: u64 = 4 * 1024;
pub const DEFAULT_TERMINAL_RESERVE_BYTES: u64 = 1024;

pub const Error = error{
    InvalidProfile,
    ResourceLimit,
    BudgetRequired,
    BudgetExhausted,
};

pub const Profile = struct {
    hard_bytes: u64 = DEFAULT_HARD_BYTES,
    soft_bytes: u64 = DEFAULT_SOFT_BYTES,
    input_cap_bytes: u64 = DEFAULT_INPUT_CAP_BYTES,
    provider_request_cap_bytes: u64 = DEFAULT_PROVIDER_REQUEST_CAP_BYTES,
    provider_result_cap_bytes: u64 = DEFAULT_PROVIDER_RESULT_CAP_BYTES,
    tool_result_cap_bytes: u64 = DEFAULT_TOOL_RESULT_CAP_BYTES,
    mcp_result_cap_bytes: u64 = DEFAULT_MCP_RESULT_CAP_BYTES,
    audit_reserve_bytes: u64 = DEFAULT_AUDIT_RESERVE_BYTES,
    terminal_reserve_bytes: u64 = DEFAULT_TERMINAL_RESERVE_BYTES,

    pub fn validate(self: Profile) Error!void {
        (checkpoint.Limits{ .hard_bytes = self.hard_bytes }).validate() catch
            return error.InvalidProfile;
        const exhausted_terminal = checkpoint.encodedTextMessageBytes(
            BUDGET_EXHAUSTED_MARKER,
        ) catch return error.InvalidProfile;
        const resource_terminal = checkpoint.encodedTextMessageBytes(
            RESOURCE_LIMIT_MARKER,
        ) catch return error.InvalidProfile;
        const minimum_terminal = @max(exhausted_terminal, resource_terminal);
        if (self.soft_bytes < checkpoint.MIN_CHECKPOINT_BUDGET or
            self.soft_bytes >= self.hard_bytes or
            self.input_cap_bytes == 0 or
            self.provider_request_cap_bytes == 0 or
            self.provider_result_cap_bytes == 0 or
            self.tool_result_cap_bytes == 0 or
            self.mcp_result_cap_bytes == 0 or
            self.audit_reserve_bytes == 0 or
            self.terminal_reserve_bytes < minimum_terminal)
            return error.InvalidProfile;
        for ([_]u64{
            self.input_cap_bytes,
            self.provider_request_cap_bytes,
            self.provider_result_cap_bytes,
            self.tool_result_cap_bytes,
            self.mcp_result_cap_bytes,
            self.audit_reserve_bytes,
            self.terminal_reserve_bytes,
        }) |value| if (value >= self.hard_bytes) return error.InvalidProfile;
        // Every admitted payload that can become one durable Conversation
        // string must fit the checkpoint codec's per-string limit. Provider
        // request bytes are transient wire data and are intentionally not part
        // of this set.
        const max_durable_string = self.checkpointLimits().max_string_bytes;
        for ([_]u64{
            self.input_cap_bytes,
            self.provider_result_cap_bytes,
            self.tool_result_cap_bytes,
            self.mcp_result_cap_bytes,
        }) |value| if (value > max_durable_string) return error.InvalidProfile;
        _ = try self.minimumRunReserve();
    }

    pub fn checkpointLimits(self: Profile) checkpoint.Limits {
        return .{
            .hard_bytes = self.hard_bytes,
            .max_section_bytes = @min(
                checkpoint.DEFAULT_MAX_SECTION_BYTES,
                self.hard_bytes,
            ),
            .max_string_bytes = @min(
                checkpoint.DEFAULT_MAX_STRING_BYTES,
                self.hard_bytes,
            ),
        };
    }

    /// Intersect caller-requested streaming limits with the Session's durable
    /// budget. The codec measures before the first sink write, so this keeps
    /// the post-sink generation commit infallible.
    pub fn boundCheckpointLimits(
        self: Profile,
        requested: checkpoint.Limits,
    ) Error!checkpoint.Limits {
        requested.validate() catch return error.InvalidProfile;
        const profile_limits = self.checkpointLimits();
        const max_section = @min(
            requested.max_section_bytes,
            profile_limits.max_section_bytes,
        );
        return .{
            .hard_bytes = @min(requested.hard_bytes, profile_limits.hard_bytes),
            .chunk_bytes = requested.chunk_bytes,
            .max_section_bytes = max_section,
            .max_string_bytes = @min(
                requested.max_string_bytes,
                @min(profile_limits.max_string_bytes, max_section),
            ),
            .max_messages = requested.max_messages,
            .max_blocks_per_message = requested.max_blocks_per_message,
        };
    }

    pub fn minimumRunReserve(self: Profile) Error!u64 {
        var result = try checkedAdd(
            self.provider_result_cap_bytes,
            self.audit_reserve_bytes,
        );
        result = try checkedAdd(result, self.terminal_reserve_bytes);
        if (result >= self.hard_bytes) return error.InvalidProfile;
        return result;
    }
};

pub const Outcome = enum(u8) {
    none,
    budget_required,
    budget_exhausted,
    resource_limit,
};

pub const Description = struct {
    hard_bytes: u64,
    soft_bytes: u64,
    durable_usage_bytes: u64,
    available_bytes: u64,
    compaction_recommended: bool,
    last_outcome: Outcome,
    required_bytes: u64,
};

pub const SessionState = struct {
    profile: Profile,
    durable_usage_bytes: u64 = 0,
    last_outcome: Outcome = .none,
    required_bytes: u64 = 0,

    pub fn init(profile: Profile) Error!SessionState {
        try profile.validate();
        return .{ .profile = profile };
    }

    pub fn updateUsage(self: *SessionState, usage: u64) Error!void {
        if (usage > self.profile.hard_bytes) return error.ResourceLimit;
        self.durable_usage_bytes = usage;
    }

    /// Commit a usage value already bounded by the canonical checkpoint
    /// codec. This is intentionally infallible after a Host sink succeeds.
    pub fn commitVerifiedUsage(self: *SessionState, usage: u64) void {
        std.debug.assert(usage <= self.profile.hard_bytes);
        self.durable_usage_bytes = usage;
    }

    pub fn recordRequired(self: *SessionState, required: u64) void {
        self.last_outcome = .budget_required;
        self.required_bytes = required;
    }

    pub fn recordRun(
        self: *SessionState,
        outcome: Outcome,
        required: u64,
        usage: u64,
    ) Error!void {
        try self.updateUsage(usage);
        self.last_outcome = outcome;
        self.required_bytes = required;
    }

    pub fn describe(self: *const SessionState) Description {
        return .{
            .hard_bytes = self.profile.hard_bytes,
            .soft_bytes = self.profile.soft_bytes,
            .durable_usage_bytes = self.durable_usage_bytes,
            .available_bytes = self.profile.hard_bytes - self.durable_usage_bytes,
            .compaction_recommended = self.durable_usage_bytes >= self.profile.soft_bytes,
            .last_outcome = self.last_outcome,
            .required_bytes = self.required_bytes,
        };
    }
};

pub const Preflight = struct {
    input_delta_bytes: u64,
    projected_usage_bytes: u64,
    minimum_required_bytes: u64,
};

pub fn preflight(
    profile: Profile,
    current_usage: u64,
    prompts: []const []const u8,
) Error!Preflight {
    try profile.validate();
    var raw_input: u64 = 0;
    var input_delta: u64 = 0;
    for (prompts) |prompt| {
        raw_input = try checkedAdd(raw_input, prompt.len);
        input_delta = try checkedAdd(
            input_delta,
            checkpoint.encodedTextMessageBytes(prompt) catch
                return error.ResourceLimit,
        );
    }
    return preflightProjected(profile, current_usage, raw_input, input_delta);
}

/// Multimodal companion of `preflight`: one user record built from ordered
/// text/image parts reserves its exact encoded delta, the same admission
/// invariant text prompts use. Raw input counts every borrowed payload byte
/// (text, media_type, base64 data).
pub fn preflightParts(
    profile: Profile,
    current_usage: u64,
    parts: []const core.message.UserContentPart,
) Error!Preflight {
    try profile.validate();
    var raw_input: u64 = 0;
    for (parts) |part| switch (part) {
        .text => |bytes| raw_input = try checkedAdd(raw_input, bytes.len),
        .image => |image| {
            raw_input = try checkedAdd(raw_input, image.media_type.len);
            raw_input = try checkedAdd(raw_input, image.data.len);
        },
    };
    const input_delta = checkpoint.encodedUserPartsMessageBytes(parts) catch
        return error.ResourceLimit;
    return preflightProjected(profile, current_usage, raw_input, input_delta);
}

pub fn preflightProjected(
    profile: Profile,
    current_usage: u64,
    raw_input: u64,
    input_delta: u64,
) Error!Preflight {
    try profile.validate();
    if (raw_input > profile.input_cap_bytes or
        input_delta > profile.input_cap_bytes)
        return error.BudgetRequired;
    const projected = try checkedAdd(current_usage, input_delta);
    const minimum_required = try checkedAdd(
        projected,
        try profile.minimumRunReserve(),
    );
    if (minimum_required > profile.hard_bytes) return error.BudgetRequired;
    return .{
        .input_delta_bytes = input_delta,
        .projected_usage_bytes = projected,
        .minimum_required_bytes = minimum_required,
    };
}

pub const OperationKind = enum(u8) {
    provider,
    tool,
    mcp,
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    profile: Profile,
    mutex: sync.Mutex = .{},
    estimated_usage_bytes: u64,
    root_input_delta_bytes: u64,
    reserved_bytes: u64 = 0,
    outcome_value: Outcome = .none,
    required_bytes_value: u64 = 0,
    provider_operations: u64 = 0,
    tool_operations: u64 = 0,
    mcp_operations: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        profile: Profile,
        preflight_result: Preflight,
    ) Controller {
        return .{
            .allocator = allocator,
            .profile = profile,
            .estimated_usage_bytes = preflight_result.projected_usage_bytes,
            .root_input_delta_bytes = preflight_result.input_delta_bytes,
        };
    }

    pub fn beginOperation(
        self: *Controller,
        kind: OperationKind,
        request_bytes: u64,
    ) Error!Reservation {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.outcome_value != .none) return error.BudgetExhausted;
        const request_cap = if (kind == .provider)
            self.profile.provider_request_cap_bytes
        else
            self.profile.input_cap_bytes;
        if (request_bytes > request_cap) {
            self.markOutcomeLocked(.budget_exhausted, request_bytes);
            return error.BudgetExhausted;
        }
        const payload_cap = switch (kind) {
            .provider => self.profile.provider_result_cap_bytes,
            .tool => self.profile.tool_result_cap_bytes,
            .mcp => self.profile.mcp_result_cap_bytes,
        };
        var reserved = checkedAdd(request_bytes, payload_cap) catch {
            self.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.BudgetExhausted;
        };
        reserved = checkedAdd(reserved, self.profile.audit_reserve_bytes) catch {
            self.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.BudgetExhausted;
        };
        var required = checkedAdd(
            self.estimated_usage_bytes,
            self.reserved_bytes,
        ) catch {
            self.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.BudgetExhausted;
        };
        required = checkedAdd(required, self.profile.terminal_reserve_bytes) catch {
            self.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.BudgetExhausted;
        };
        required = checkedAdd(required, reserved) catch {
            self.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.BudgetExhausted;
        };
        if (required > self.profile.hard_bytes) {
            self.markOutcomeLocked(.budget_exhausted, required);
            return error.BudgetExhausted;
        }
        self.reserved_bytes = checkedAdd(self.reserved_bytes, reserved) catch
            unreachable;
        switch (kind) {
            .provider => self.provider_operations += 1,
            .tool => self.tool_operations += 1,
            .mcp => self.mcp_operations += 1,
        }
        return .{
            .controller = self,
            .reserved_bytes = reserved,
            .payload_cap_bytes = payload_cap,
        };
    }

    /// Reserve one durable Session mutation that occurs inside a Run, such as
    /// remembering an allow_session/deny_session rule after the Host answers.
    /// The caller must reserve before publishing the mutation and then either
    /// commit or release the returned token.
    pub fn beginDurableDelta(
        self: *Controller,
        durable_delta_bytes: u64,
    ) Error!DurableReservation {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.outcome_value != .none) return error.BudgetExhausted;
        if (durable_delta_bytes == 0 or
            durable_delta_bytes > self.profile.audit_reserve_bytes)
        {
            self.markOutcomeLocked(.resource_limit, durable_delta_bytes);
            return error.BudgetExhausted;
        }
        var required = checkedAdd(
            self.estimated_usage_bytes,
            self.reserved_bytes,
        ) catch {
            self.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.BudgetExhausted;
        };
        required = checkedAdd(required, self.profile.terminal_reserve_bytes) catch {
            self.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.BudgetExhausted;
        };
        required = checkedAdd(required, durable_delta_bytes) catch {
            self.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.BudgetExhausted;
        };
        if (required > self.profile.hard_bytes) {
            self.markOutcomeLocked(.budget_exhausted, required);
            return error.BudgetExhausted;
        }
        self.reserved_bytes = checkedAdd(
            self.reserved_bytes,
            durable_delta_bytes,
        ) catch unreachable;
        return .{
            .controller = self,
            .reserved_bytes = durable_delta_bytes,
        };
    }

    /// Reconcile the exact records produced by an admitted Skill with the
    /// deterministic canonical invocation record reserved before admission.
    /// Dynamic rendering (file references and shell injection) cannot safely
    /// run before Run admission. Its durable expansion is therefore admitted
    /// atomically here, before Conversation mutation; failure records a typed
    /// admitted-Run outcome instead of pretending the effectful render was a
    /// side-effect-free preflight.
    pub fn reconcileGeneratedRootPrompts(
        self: *Controller,
        prompts: []const []const u8,
    ) Error!void {
        var raw_input: u64 = 0;
        var exact_delta: u64 = 0;
        for (prompts) |prompt| {
            raw_input = checkedAdd(raw_input, prompt.len) catch {
                self.markResourceLimit(std.math.maxInt(u64));
                return error.ResourceLimit;
            };
            exact_delta = checkedAdd(
                exact_delta,
                checkpoint.encodedTextMessageBytes(prompt) catch {
                    self.markResourceLimit(std.math.maxInt(u64));
                    return error.ResourceLimit;
                },
            ) catch {
                self.markResourceLimit(std.math.maxInt(u64));
                return error.ResourceLimit;
            };
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        if (raw_input > self.profile.input_cap_bytes or
            exact_delta > self.profile.input_cap_bytes or
            self.estimated_usage_bytes < self.root_input_delta_bytes)
        {
            self.markOutcomeLocked(.resource_limit, exact_delta);
            return error.ResourceLimit;
        }
        const base_usage = self.estimated_usage_bytes - self.root_input_delta_bytes;
        const projected = checkedAdd(base_usage, exact_delta) catch {
            self.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.ResourceLimit;
        };
        var required = checkedAdd(projected, self.reserved_bytes) catch {
            self.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.ResourceLimit;
        };
        required = checkedAdd(required, self.profile.minimumRunReserve() catch {
            self.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.ResourceLimit;
        }) catch {
            self.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.ResourceLimit;
        };
        if (required > self.profile.hard_bytes) {
            self.markOutcomeLocked(.budget_exhausted, required);
            return error.BudgetExhausted;
        }
        self.estimated_usage_bytes = projected;
        self.root_input_delta_bytes = exact_delta;
    }

    pub fn outcome(self: *Controller) Outcome {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.outcome_value;
    }

    pub fn requiredBytes(self: *Controller) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.required_bytes_value;
    }

    /// Reject a replacement-style maintenance transaction whose candidate
    /// durable state cannot fit. Unlike a Run reservation, compact does not
    /// append its provider response to the live Conversation; its commit
    /// guard evaluates the replacement checkpoint and reports failure here.
    pub fn failReplacementBudget(self: *Controller, required: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.markOutcomeLocked(.budget_exhausted, required);
    }

    fn markOutcomeLocked(
        self: *Controller,
        next_outcome: Outcome,
        required: u64,
    ) void {
        if (self.outcome_value == .none) {
            self.outcome_value = next_outcome;
            self.required_bytes_value = required;
        }
    }

    fn markResourceLimit(self: *Controller, required: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.markOutcomeLocked(.resource_limit, required);
    }
};

pub const DurableReservation = struct {
    controller: *Controller,
    reserved_bytes: u64,
    active: bool = true,

    pub fn commit(self: *DurableReservation) void {
        if (!self.active) return;
        self.controller.mutex.lock();
        defer self.controller.mutex.unlock();
        self.removeReservedLocked();
        self.controller.estimated_usage_bytes = checkedAdd(
            self.controller.estimated_usage_bytes,
            self.reserved_bytes,
        ) catch unreachable;
    }

    pub fn release(self: *DurableReservation) void {
        if (!self.active) return;
        self.controller.mutex.lock();
        defer self.controller.mutex.unlock();
        self.removeReservedLocked();
    }

    fn removeReservedLocked(self: *DurableReservation) void {
        std.debug.assert(self.active);
        std.debug.assert(self.controller.reserved_bytes >= self.reserved_bytes);
        self.controller.reserved_bytes -= self.reserved_bytes;
        self.active = false;
    }
};

pub const Reservation = struct {
    controller: *Controller,
    reserved_bytes: u64,
    payload_cap_bytes: u64,
    active: bool = true,

    pub fn payloadCap(self: *const Reservation) u64 {
        return self.payload_cap_bytes;
    }

    pub fn settleSuccess(
        self: *Reservation,
        payload_bytes: u64,
        durable_delta_bytes: u64,
    ) Error!void {
        if (!self.active) return;
        self.controller.mutex.lock();
        defer self.controller.mutex.unlock();
        self.removeReservedLocked();
        if (payload_bytes > self.payload_cap_bytes) {
            self.controller.markOutcomeLocked(.resource_limit, payload_bytes);
            return error.ResourceLimit;
        }
        const durable_with_audit = checkedAdd(
            durable_delta_bytes,
            self.controller.profile.audit_reserve_bytes,
        ) catch {
            self.controller.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.ResourceLimit;
        };
        const next = checkedAdd(
            self.controller.estimated_usage_bytes,
            durable_with_audit,
        ) catch {
            self.controller.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.ResourceLimit;
        };
        // Live sibling reservations still own their share of the hard budget.
        // A settle that only fits by eating them (an inline image whose durable
        // bytes exceed its own payload_cap reservation) is a resource limit
        // here, not a surprise the sibling discovers after its own side effect.
        // For a settle within its reservation this is never stricter than the
        // admission check in beginOperation.
        const committed = checkedAdd(next, self.controller.reserved_bytes) catch {
            self.controller.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.ResourceLimit;
        };
        // Same convention as beginOperation: the requirement reported as
        // required_checkpoint_bytes is what must fit under hard_bytes, i.e.
        // committed usage plus live sibling reservations plus the terminal
        // reserve. A host can compare it with hard_bytes directly.
        const required = checkedAdd(committed, self.controller.profile.terminal_reserve_bytes) catch {
            self.controller.markOutcomeLocked(.resource_limit, std.math.maxInt(u64));
            return error.ResourceLimit;
        };
        if (required > self.controller.profile.hard_bytes) {
            self.controller.markOutcomeLocked(.resource_limit, required);
            return error.ResourceLimit;
        }
        self.controller.estimated_usage_bytes = next;
    }

    pub fn failResourceLimit(self: *Reservation, required: u64) void {
        if (!self.active) return;
        self.controller.mutex.lock();
        defer self.controller.mutex.unlock();
        self.removeReservedLocked();
        self.controller.markOutcomeLocked(.resource_limit, required);
    }

    pub fn release(self: *Reservation) void {
        if (!self.active) return;
        self.controller.mutex.lock();
        defer self.controller.mutex.unlock();
        self.removeReservedLocked();
    }

    fn removeReservedLocked(self: *Reservation) void {
        std.debug.assert(self.active);
        std.debug.assert(self.controller.reserved_bytes >= self.reserved_bytes);
        self.controller.reserved_bytes -= self.reserved_bytes;
        self.active = false;
    }
};

pub const ToolEnvironment = struct {
    controller: *Controller,
    base: core.agent_session.RunToolSurface,

    pub fn surface(self: *const ToolEnvironment) core.agent_session.RunToolSurface {
        return .{
            .definitions = self.base.definitions,
            .dispatcher = .{
                .ctx = self,
                .dispatchFn = dispatch,
                .metadataFn = metadata,
                .nameAtFn = nameAt,
            },
        };
    }

    fn dispatch(
        raw: *const anyopaque,
        tool_ctx: *const core.tool_context.ToolContext,
        name: []const u8,
        arguments_json: []const u8,
    ) anyerror!core.tools.ToolDispatchOutcome {
        const self: *const ToolEnvironment = @ptrCast(@alignCast(raw));
        // Classification must share dispatch's resolution authority. The old
        // unfiltered-View lookup drifted from the freshness-filtered MCP
        // Environment: a selected-but-expired alias reserved under MCP caps
        // while dispatch answered UnknownTool. The base metadata resolution
        // reports MCP aliases (and every other out-of-process executor) as
        // `.external`, so exactly those reserve under the external/MCP caps;
        // builtin/host and unresolvable names stay on the Tool caps.
        const kind: OperationKind = if (self.base.dispatcher.metadata(name)) |meta|
            switch (meta.kind) {
                .external => .mcp,
                .builtin, .host => .tool,
            }
        else
            .tool;
        const request_bytes = checkedAdd(
            try checkedAdd(name.len, arguments_json.len),
            64,
        ) catch return boundedToolOutcome(tool_ctx.allocator, BUDGET_EXHAUSTED_MARKER);
        var reservation = self.controller.beginOperation(
            kind,
            request_bytes,
        ) catch return boundedToolOutcome(
            tool_ctx.allocator,
            BUDGET_EXHAUSTED_MARKER,
        );
        var outcome = self.base.dispatcher.dispatch(
            tool_ctx,
            name,
            arguments_json,
        ) catch |err| {
            reservation.release();
            return err;
        };
        var outcome_live = true;
        errdefer if (outcome_live) outcome.deinit(tool_ctx.allocator);
        errdefer reservation.release();
        const payload_cap = switch (kind) {
            .tool => self.controller.profile.tool_result_cap_bytes,
            .mcp => self.controller.profile.mcp_result_cap_bytes,
            .provider => unreachable,
        };
        // Image results mirror the Conversation projection seam: promoting a
        // picture to an artifact would hand the dialects an envelope instead of
        // an image, so it stays inline. The payload cap is charged at the vision
        // estimate (what the model actually pays); the durable budget below is
        // charged for the real bytes (what the checkpoint actually stores).
        const inline_image = outcome == .ok and outcome.ok == .@"inline" and
            core.result_projection.isImageResult(outcome.ok.@"inline".bytes);
        if (outcome == .ok and outcome.ok == .@"inline" and !inline_image and
            outcome.ok.rawBytes() > payload_cap)
        {
            _ = outcome.ok.promoteInline(
                tool_ctx.allocator,
                tool_ctx.artifact_root,
            ) catch |err| {
                const required = outcome.ok.rawBytes();
                if (err == error.OutOfMemory) {
                    return error.OutOfMemory;
                }
                outcome.deinit(tool_ctx.allocator);
                outcome_live = false;
                reservation.failResourceLimit(required);
                return boundedToolOutcome(tool_ctx.allocator, RESOURCE_LIMIT_MARKER);
            };
        }
        const payload_bytes: u64 = switch (outcome) {
            .ok => |*body| if (inline_image)
                core.result_projection.IMAGE_RESULT_BUDGET_BYTES
            else
                @intCast(try body.modelVisibleBytes(tool_ctx.allocator)),
            .host_failed, .host_rejected => |maybe| if (maybe) |bytes|
                @intCast(bytes.len)
            else
                0,
            .host_fatal => {
                reservation.release();
                return outcome;
            },
        };
        const durable_bytes: u64 = if (inline_image) outcome.ok.rawBytes() else payload_bytes;
        const durable_delta = checkedAdd(durable_bytes, 32) catch
            std.math.maxInt(u64);
        reservation.settleSuccess(payload_bytes, durable_delta) catch {
            outcome.deinit(tool_ctx.allocator);
            outcome_live = false;
            return boundedToolOutcome(tool_ctx.allocator, RESOURCE_LIMIT_MARKER);
        };
        return outcome;
    }

    /// Budgeting is a pure dispatch decorator: name-level execution metadata
    /// is delegated wholesale, so the base resolution (builtin identity,
    /// category, replay, scheduling flags) survives this layer unmodified.
    fn metadata(raw: *const anyopaque, name: []const u8) ?core.tools.ToolMeta {
        const self: *const ToolEnvironment = @ptrCast(@alignCast(raw));
        return self.base.dispatcher.metadata(name);
    }

    fn nameAt(raw: *const anyopaque, index: usize) ?[]const u8 {
        const self: *const ToolEnvironment = @ptrCast(@alignCast(raw));
        return self.base.dispatcher.nameAt(index);
    }
};

fn boundedToolOutcome(
    allocator: std.mem.Allocator,
    marker: []const u8,
) error{OutOfMemory}!core.tools.ToolDispatchOutcome {
    return .{ .host_failed = try allocator.dupe(u8, marker) };
}

pub const BudgetedProvider = struct {
    allocator: std.mem.Allocator,
    controller: *Controller,
    base: core.api_provider.Provider,

    pub fn provider(self: *BudgetedProvider) core.api_provider.Provider {
        return .{
            .ctx = self,
            .modelFn = model,
            .sendStreamFn = sendStream,
            .sendStreamRetryFn = sendStreamRetry,
            .sendFn = send,
            .cancelFn = cancel,
            .maxTokensFn = maxTokens,
            // AgentCore compact is an explicit idle activity. Returning the
            // largest neutral window prevents shared automatic compaction;
            // explicit provider context failures are translated below.
            .maxInputTokensFn = maxInputTokens,
            .reasoningEffortFn = reasoningEffort,
            .supportsFn = supports,
        };
    }

    fn model(raw: *anyopaque) []const u8 {
        return cast(raw).base.model();
    }

    fn sendStream(
        raw: *anyopaque,
        messages: []const core.types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const core.json.ToolDefinition,
        abort: ?*const core.util_abort.AbortSignal,
        model_override: ?[]const u8,
        tool_choice: ?core.json.ToolChoice,
        user_query: []const u8,
    ) anyerror!core.api_provider.StreamHandle {
        const self = cast(raw);
        var reservation = try self.beginProvider(
            messages,
            system,
            tools,
            tool_choice,
            model_override,
        );
        const base_stream = self.base.sendStream(
            messages,
            system,
            tools,
            abort,
            model_override,
            tool_choice,
            user_query,
        ) catch |err| {
            reservation.release();
            return translateContextError(err);
        };
        return self.wrapStream(base_stream, reservation);
    }

    fn sendStreamRetry(
        raw: *anyopaque,
        messages: []const core.types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const core.json.ToolDefinition,
        abort: ?*const core.util_abort.AbortSignal,
        model_override: ?[]const u8,
        tool_choice: ?core.json.ToolChoice,
        max_retries: u32,
        retry_base_ms: u64,
        reporter: ?core.api_provider.RetryReporter,
        user_query: []const u8,
    ) anyerror!core.api_provider.StreamHandle {
        const self = cast(raw);
        var reservation = try self.beginProvider(
            messages,
            system,
            tools,
            tool_choice,
            model_override,
        );
        const base_stream = self.base.sendStreamRetry(
            messages,
            system,
            tools,
            abort,
            model_override,
            tool_choice,
            max_retries,
            retry_base_ms,
            reporter,
            user_query,
        ) catch |err| {
            reservation.release();
            return translateContextError(err);
        };
        return self.wrapStream(base_stream, reservation);
    }

    fn send(
        raw: *anyopaque,
        messages: []const core.types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const core.json.ToolDefinition,
        model_override: ?[]const u8,
    ) anyerror!core.api_provider.ApiResponse {
        const self = cast(raw);
        var reservation = try self.beginProvider(
            messages,
            system,
            tools,
            null,
            model_override,
        );
        const response = self.base.sendWithModel(
            messages,
            system,
            tools,
            model_override,
        ) catch |err| {
            reservation.release();
            return translateContextError(err);
        };
        const measured = measureApiResponse(response) catch {
            deinitApiResponse(self.allocator, response);
            reservation.failResourceLimit(std.math.maxInt(u64));
            return error.CheckpointPayloadTooLarge;
        };
        reservation.settleSuccess(measured.payload, measured.durable) catch {
            deinitApiResponse(self.allocator, response);
            return error.CheckpointPayloadTooLarge;
        };
        return response;
    }

    fn beginProvider(
        self: *BudgetedProvider,
        messages: []const core.types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const core.json.ToolDefinition,
        tool_choice: ?core.json.ToolChoice,
        model_override: ?[]const u8,
    ) anyerror!Reservation {
        // 路由能否原生收图决定图片工具结果在 wire 上是 base64 还是占位符(见
        // request.zig 的序列化);按配置模型判定,model_override 跨能力类别时估算偏保守。
        const request_bytes = try canonicalRequestBytes(
            self.allocator,
            model_override orelse self.base.model(),
            self.base.maxTokens(),
            messages,
            system,
            tools,
            tool_choice,
            self.base.supports(.image_input),
        );
        return self.controller.beginOperation(.provider, request_bytes) catch
            return error.CheckpointBudgetExhausted;
    }

    fn wrapStream(
        self: *BudgetedProvider,
        base_stream: core.api_provider.StreamHandle,
        reservation: Reservation,
    ) error{OutOfMemory}!core.api_provider.StreamHandle {
        const wrapper = self.allocator.create(StreamWrapper) catch {
            base_stream.deinit();
            var owned_reservation = reservation;
            owned_reservation.release();
            return error.OutOfMemory;
        };
        wrapper.* = .{
            .allocator = self.allocator,
            .controller = self.controller,
            .base = base_stream,
            .reservation = reservation,
        };
        return wrapper.handle();
    }

    fn cancel(raw: *anyopaque, signal: *const core.util_abort.AbortSignal) void {
        cast(raw).base.cancel(signal);
    }

    fn maxTokens(raw: *anyopaque) u32 {
        return cast(raw).base.maxTokens();
    }

    fn maxInputTokens(_: *anyopaque) u32 {
        return std.math.maxInt(u32);
    }

    fn reasoningEffort(raw: *anyopaque) ?core.types.ReasoningEffort {
        return cast(raw).base.reasoningEffort();
    }

    fn supports(raw: *anyopaque, capability: core.api_provider.Capability) bool {
        return cast(raw).base.supports(capability);
    }

    fn cast(raw: *anyopaque) *BudgetedProvider {
        return @ptrCast(@alignCast(raw));
    }
};

const StreamWrapper = struct {
    allocator: std.mem.Allocator,
    controller: *Controller,
    base: core.api_provider.StreamHandle,
    reservation: Reservation,
    buffered: std.ArrayList(core.api_stream.StreamEvent) = .empty,
    next_index: usize = 0,
    payload_bytes: u64 = 0,
    durable_delta_bytes: u64 = 0,
    loaded: bool = false,
    complete: bool = false,

    fn handle(self: *StreamWrapper) core.api_provider.StreamHandle {
        return .{
            .ctx = self,
            // The serialization decision belongs to the base stream; pass it through untouched.
            .image_placeholder_ids = self.base.image_placeholder_ids,
            .nextFn = next,
            .deinitFn = deinit,
            .stopReasonFn = stopReason,
            .requestIdFn = requestId,
        };
    }

    fn next(raw: *anyopaque) anyerror!?core.api_stream.StreamEvent {
        const self = cast(raw);
        if (!self.loaded) try self.loadAndValidate();
        if (self.next_index == self.buffered.items.len) return null;
        const event = self.buffered.items[self.next_index];
        self.next_index += 1;
        return event;
    }

    /// Provider streams are held behind this bounded spool until the complete
    /// canonical response is known to fit. Releasing chunks optimistically
    /// would let an oversized tail leave an uncheckpointable partial response
    /// in the shared agent loop.
    fn loadAndValidate(self: *StreamWrapper) anyerror!void {
        std.debug.assert(!self.loaded);
        if (self.controller.outcome() != .none) {
            self.reservation.release();
            self.loaded = true;
            self.complete = true;
            return;
        }
        while (true) {
            const maybe_event = self.base.next() catch |err| {
                self.clearBuffered();
                self.reservation.release();
                return translateContextError(err);
            };
            const event = maybe_event orelse break;
            const measured = measureStreamEvent(event) catch {
                deinitStreamEvent(self.allocator, event);
                self.clearBuffered();
                self.reservation.failResourceLimit(std.math.maxInt(u64));
                self.loaded = true;
                self.complete = true;
                return;
            };
            const next_payload = checkedAdd(
                self.payload_bytes,
                measured.payload,
            ) catch {
                deinitStreamEvent(self.allocator, event);
                self.clearBuffered();
                self.reservation.failResourceLimit(std.math.maxInt(u64));
                self.loaded = true;
                self.complete = true;
                return;
            };
            const next_durable = checkedAdd(
                self.durable_delta_bytes,
                measured.durable,
            ) catch {
                deinitStreamEvent(self.allocator, event);
                self.clearBuffered();
                self.reservation.failResourceLimit(std.math.maxInt(u64));
                self.loaded = true;
                self.complete = true;
                return;
            };
            if (next_payload > self.reservation.payloadCap()) {
                deinitStreamEvent(self.allocator, event);
                self.clearBuffered();
                self.reservation.failResourceLimit(next_payload);
                self.loaded = true;
                self.complete = true;
                return;
            }
            self.buffered.append(self.allocator, event) catch {
                deinitStreamEvent(self.allocator, event);
                self.clearBuffered();
                self.reservation.release();
                return error.OutOfMemory;
            };
            self.payload_bytes = next_payload;
            self.durable_delta_bytes = next_durable;
        }
        self.reservation.settleSuccess(
            self.payload_bytes,
            self.durable_delta_bytes,
        ) catch {
            self.clearBuffered();
        };
        self.loaded = true;
        self.complete = true;
    }

    fn deinit(raw: *anyopaque) void {
        const self = cast(raw);
        self.base.deinit();
        if (!self.complete) self.reservation.release();
        self.clearBuffered();
        self.buffered.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn stopReason(raw: *anyopaque) core.api_stream.StopReason {
        const self = cast(raw);
        return if (self.controller.outcome() == .none)
            self.base.stopReason()
        else
            .end_turn;
    }

    fn requestId(raw: *anyopaque) core.util_log.RequestId {
        return cast(raw).base.requestId();
    }

    fn cast(raw: *anyopaque) *StreamWrapper {
        return @ptrCast(@alignCast(raw));
    }

    fn clearBuffered(self: *StreamWrapper) void {
        for (self.buffered.items[self.next_index..]) |event|
            deinitStreamEvent(self.allocator, event);
        self.buffered.clearRetainingCapacity();
        self.next_index = 0;
    }
};

const MeasuredPayload = struct { payload: u64, durable: u64 };

fn measureStreamEvent(event: core.api_stream.StreamEvent) Error!MeasuredPayload {
    return switch (event) {
        .text, .thinking => |bytes| .{
            .payload = @intCast(bytes.len),
            .durable = try checkedAdd(bytes.len, 14),
        },
        .tool_use_start => |tool| blk: {
            var payload = try checkedAdd(tool.id.len, tool.name.len);
            payload = try checkedAdd(payload, tool.input_json.len);
            // The provider result stores id/name/input once. A later paired
            // tool_result stores the id again, so reserve that future envelope
            // here while the identifier is available.
            var durable = try checkedAdd(payload, 30);
            durable = try checkedAdd(durable, tool.id.len + 18);
            break :blk .{ .payload = payload, .durable = durable };
        },
        .web_search_result => |result| .{
            .payload = try checkedAdd(result.ui_text.len, result.content_json.len),
            .durable = try checkedAdd(result.ui_text.len, 14),
        },
        .web_search_query => |query| .{
            .payload = @intCast(query.len),
            .durable = 0,
        },
        .usage, .done => .{ .payload = 0, .durable = 0 },
    };
}

fn measureApiResponse(response: core.api_provider.ApiResponse) Error!MeasuredPayload {
    var payload: u64 = @intCast(response.content.len);
    var durable = try checkedAdd(response.content.len, 14);
    for (response.tool_calls) |tool| {
        payload = try checkedAdd(payload, tool.id.len);
        payload = try checkedAdd(payload, tool.name.len);
        payload = try checkedAdd(payload, tool.input.len);
        durable = try checkedAdd(durable, tool.id.len + tool.name.len + tool.input.len + 48);
    }
    return .{ .payload = payload, .durable = durable };
}

fn deinitApiResponse(
    response_allocator: std.mem.Allocator,
    response: core.api_provider.ApiResponse,
) void {
    if (response.content.len != 0)
        response_allocator.free(@constCast(response.content));
    if (response.tool_calls.len != 0)
        response_allocator.free(@constCast(response.tool_calls));
}

fn deinitStreamEvent(
    allocator: std.mem.Allocator,
    event: core.api_stream.StreamEvent,
) void {
    switch (event) {
        .text, .thinking => |bytes| allocator.free(bytes),
        .tool_use_start => |tool| {
            allocator.free(tool.id);
            allocator.free(tool.name);
            allocator.free(tool.input_json);
        },
        .web_search_result => |result| {
            allocator.free(result.ui_text);
            allocator.free(result.content_json);
        },
        .web_search_query => |query| allocator.free(query),
        .usage, .done => {},
    }
}

fn canonicalRequestBytes(
    allocator: std.mem.Allocator,
    model: []const u8,
    max_tokens: u32,
    messages: []const core.types.ApiMessage,
    system: ?[]const u8,
    tools: ?[]const core.json.ToolDefinition,
    tool_choice: ?core.json.ToolChoice,
    images_native: bool,
) anyerror!u64 {
    // 图像经估算投影序列化(占位替换):canonical 测量统一走 Anthropic 序列化器,
    // 非 claude vision 模型带图会因守门报错 → 预算 admission 拒绝一个 provider 本会
    // 接受的请求。真实载荷字节(base64 data + MIME + 每图 ~64B wire 信封)在投影后
    // 加回,保持"每请求 wire 字节"的测量语义与无图请求的既有口径一致。
    // 图片工具结果只在路由原生收图时加回:纯文本路由的真实序列化器发的是短占位符
    // (request.zig),投影后的占位已计入 encoded;若仍按 base64 长度加回,四张接近
    // 16 MiB 图片允量的结果会让纯文本路由误报 checkpoint_budget_exhausted,且这些
    // 结果不可裁剪、后续每轮重复拒绝。首类 .image 块一律加回:不收图的路由在真实
    // 序列化时直接报错,估算偏保守无害。
    const projection = try core.agent_loop.projectImagesForEstimation(allocator, messages);
    defer if (projection) |p| p.deinit(allocator);
    const effective: []const core.types.ApiMessage = if (projection) |p| p.messages else messages;
    const encoded = try core.json.serializeMessagesRequest(.{
        .model = model,
        .max_tokens = max_tokens,
        .messages = effective,
        .system = system,
        .stream = true,
        .tools = tools,
        .tool_choice = tool_choice,
    }, allocator);
    defer allocator.free(encoded);
    var payload_bytes: u64 = 0;
    for (messages) |m| for (m.content) |c| switch (c) {
        .image => |img| payload_bytes +|= @as(u64, img.data.len) +| img.media_type.len +| 64,
        .tool_result => |tr| if (images_native and core.json.extractImageResult(tr.content) != null) {
            payload_bytes +|= @as(u64, tr.content.len);
        },
        else => {},
    };
    return @as(u64, @intCast(encoded.len)) +| payload_bytes;
}

fn translateContextError(err: anyerror) anyerror {
    if (err == error.ContextWindowExceeded)
        return error.AgentCoreContextLimitRequiresExplicitCompact;
    return err;
}

fn checkedAdd(left: anytype, right: anytype) Error!u64 {
    return std.math.add(u64, @intCast(left), @intCast(right)) catch
        return error.ResourceLimit;
}

test "pre-admission budget rejection consumes no operation state" {
    const profile = Profile{
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
    const accepted = try preflight(profile, 1000, &.{"small"});
    try std.testing.expect(accepted.projected_usage_bytes > 1000);
    try std.testing.expectError(
        error.BudgetRequired,
        preflight(profile, 3500, &.{"cannot fit"}),
    );
}

test "Skill root budget reserves exact invocation then reconciles admitted expansion" {
    const profile = Profile{
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
    const invocation = "canonical invocation";
    const admitted = try preflight(profile, 1000, &.{invocation});
    try std.testing.expectEqual(
        @as(u64, 1000) + try checkpoint.encodedTextMessageBytes(invocation),
        admitted.projected_usage_bytes,
    );
    try std.testing.expect(admitted.input_delta_bytes < profile.input_cap_bytes);
    var controller = Controller.init(std.testing.allocator, profile, admitted);
    try controller.reconcileGeneratedRootPrompts(&.{ invocation, "rendered body" });
    try std.testing.expectEqual(Outcome.none, controller.outcome());

    const tight = try preflight(profile, 3000, &.{invocation});
    var tight_controller = Controller.init(std.testing.allocator, profile, tight);
    var expansion: [800]u8 = undefined;
    @memset(&expansion, 'x');
    try std.testing.expectError(
        error.BudgetExhausted,
        tight_controller.reconcileGeneratedRootPrompts(&.{ invocation, &expansion }),
    );
    try std.testing.expectEqual(Outcome.budget_exhausted, tight_controller.outcome());
}

test "durable payload caps cannot exceed checkpoint string encoding capacity" {
    const twenty_mib = 20 * 1024 * 1024;
    var profile = Profile{
        .hard_bytes = 64 * 1024 * 1024,
        .soft_bytes = 48 * 1024 * 1024,
        .tool_result_cap_bytes = twenty_mib,
    };
    try std.testing.expectEqual(
        @as(u64, checkpoint.DEFAULT_MAX_STRING_BYTES),
        profile.checkpointLimits().max_string_bytes,
    );
    try std.testing.expectError(error.InvalidProfile, profile.validate());

    // Provider requests are transient wire payloads, not one durable
    // Conversation string, so a larger request cap does not violate the codec
    // invariant.
    profile.tool_result_cap_bytes = DEFAULT_TOOL_RESULT_CAP_BYTES;
    profile.provider_request_cap_bytes = twenty_mib;
    try profile.validate();
}

test "checkpoint limits are intersected with the Session durable profile" {
    const profile = Profile{
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
    const bounded = try profile.boundCheckpointLimits(.{
        .hard_bytes = 1024 * 1024,
        .chunk_bytes = 73,
        .max_section_bytes = 512 * 1024,
        .max_string_bytes = 256 * 1024,
        .max_messages = 321,
        .max_blocks_per_message = 17,
    });
    try std.testing.expectEqual(profile.hard_bytes, bounded.hard_bytes);
    try std.testing.expectEqual(profile.hard_bytes, bounded.max_section_bytes);
    try std.testing.expectEqual(profile.hard_bytes, bounded.max_string_bytes);
    try std.testing.expectEqual(@as(usize, 73), bounded.chunk_bytes);
    try std.testing.expectEqual(@as(u64, 321), bounded.max_messages);
    try std.testing.expectEqual(@as(u64, 17), bounded.max_blocks_per_message);
}

test "settle beyond its own reservation cannot consume a live sibling reservation" {
    const profile = Profile{
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
    const admitted = try preflight(profile, 1000, &.{"run"});
    // Reference: alone, a durable delta that fills the hard budget exactly settles.
    var alone = Controller.init(std.testing.allocator, profile, admitted);
    var solo = try alone.beginOperation(.tool, 32);
    const room = profile.hard_bytes - profile.terminal_reserve_bytes - alone.estimated_usage_bytes - profile.audit_reserve_bytes;
    try solo.settleSuccess(10, room);
    try std.testing.expectEqual(Outcome.none, alone.outcome());

    // With a sibling reservation live, the same delta would eat the sibling's
    // share: it must be refused at settle time, and the sibling keeps its space.
    var controller = Controller.init(std.testing.allocator, profile, admitted);
    var first = try controller.beginOperation(.tool, 32);
    var second = try controller.beginOperation(.tool, 32);
    const sibling_reserved = controller.reserved_bytes / 2;
    try std.testing.expectError(error.ResourceLimit, first.settleSuccess(10, room));
    try std.testing.expectEqual(Outcome.resource_limit, controller.outcome());
    try std.testing.expectEqual(sibling_reserved, controller.reserved_bytes);
    // The reported requirement is what would have to fit under hard_bytes:
    // committed usage + the sibling share that caused the refusal + terminal reserve.
    try std.testing.expectEqual(profile.hard_bytes + sibling_reserved, controller.requiredBytes());
    second.release();
    try std.testing.expectEqual(@as(u64, 0), controller.reserved_bytes);

    // No sibling, but the delta lands between hard - terminal and hard: refused,
    // and the report includes the terminal reserve so it exceeds hard_bytes.
    var terminal_case = Controller.init(std.testing.allocator, profile, admitted);
    var only = try terminal_case.beginOperation(.tool, 32);
    try std.testing.expectError(error.ResourceLimit, only.settleSuccess(10, room + 64));
    try std.testing.expectEqual(profile.hard_bytes + 64, terminal_case.requiredBytes());
}

test "operation reservations are atomic and preserve terminal space" {
    const profile = Profile{
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
    const admitted = try preflight(profile, 1000, &.{"run"});
    var controller = Controller.init(std.testing.allocator, profile, admitted);
    var reservation = try controller.beginOperation(.tool, 32);
    try reservation.settleSuccess(10, 42);
    try std.testing.expectEqual(Outcome.none, controller.outcome());
    try std.testing.expectEqual(@as(u64, 1), controller.tool_operations);

    var overflow = try controller.beginOperation(.mcp, 32);
    overflow.failResourceLimit(300);
    try std.testing.expectEqual(Outcome.resource_limit, controller.outcome());
    try std.testing.expectEqual(@as(u64, 0), controller.reserved_bytes);
}

const TestProvider = struct {
    allocator: std.mem.Allocator,
    calls: u32 = 0,
    payload_bytes: usize = 0,
    stream_event_kind: TestStream.EventKind = .text,
    stream: TestStream = undefined,

    fn provider(self: *TestProvider) core.api_provider.Provider {
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
        return "budget-test";
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
        const self: *TestProvider = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.stream = .{
            .allocator = self.allocator,
            .payload_bytes = self.payload_bytes,
            .request_id = core.util_log.genRequestId(),
            .event_kind = self.stream_event_kind,
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
        raw: *anyopaque,
        _: []const core.types.ApiMessage,
        _: ?[]const u8,
        _: ?[]const core.json.ToolDefinition,
        _: ?[]const u8,
    ) anyerror!core.api_provider.ApiResponse {
        const self: *TestProvider = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .{ .content = try self.allocator.alloc(u8, self.payload_bytes) };
    }

    fn maxTokens(_: *anyopaque) u32 {
        return 1024;
    }

    fn maxInputTokens(_: *anyopaque) u32 {
        return 4096;
    }

    fn reasoningEffort(_: *anyopaque) ?core.types.ReasoningEffort {
        return null;
    }

    fn supports(_: *anyopaque, _: core.api_provider.Capability) bool {
        return false;
    }
};

const TestStream = struct {
    const EventKind = enum { text, thinking };

    allocator: std.mem.Allocator,
    payload_bytes: usize,
    request_id: core.util_log.RequestId,
    event_kind: EventKind = .text,
    emitted: bool = false,

    fn handle(self: *TestStream) core.api_provider.StreamHandle {
        return .{
            .ctx = self,
            .nextFn = next,
            .deinitFn = deinit,
            .stopReasonFn = stopReason,
            .requestIdFn = requestId,
        };
    }

    fn next(raw: *anyopaque) anyerror!?core.api_stream.StreamEvent {
        const self: *TestStream = @ptrCast(@alignCast(raw));
        if (self.emitted) return null;
        self.emitted = true;
        const bytes = try self.allocator.alloc(u8, self.payload_bytes);
        @memset(bytes, 'x');
        return switch (self.event_kind) {
            .text => .{ .text = bytes },
            .thinking => .{ .thinking = bytes },
        };
    }

    fn deinit(_: *anyopaque) void {}

    fn stopReason(_: *anyopaque) core.api_stream.StopReason {
        return .end_turn;
    }

    fn requestId(raw: *anyopaque) core.util_log.RequestId {
        const self: *TestStream = @ptrCast(@alignCast(raw));
        return self.request_id;
    }
};

const TestDispatcher = struct {
    calls: u32 = 0,
    payload_bytes: usize,

    fn dispatcher(self: *TestDispatcher) core.tools.ToolDispatcher {
        return .{
            .ctx = self,
            .dispatchFn = dispatch,
            .metadataFn = metadata,
            .nameAtFn = noName,
        };
    }

    fn dispatch(
        raw: *const anyopaque,
        tool_ctx: *const core.tool_context.ToolContext,
        _: []const u8,
        _: []const u8,
    ) anyerror!core.tools.ToolDispatchOutcome {
        const self: *TestDispatcher = @ptrCast(@alignCast(@constCast(raw)));
        self.calls += 1;
        const bytes = try tool_ctx.allocator.alloc(u8, self.payload_bytes);
        @memset(bytes, 't');
        return .{ .ok = core.tools.ToolResultBody.initInline(bytes) };
    }

    fn metadata(_: *const anyopaque, name: []const u8) ?core.tools.ToolMeta {
        if (std.mem.eql(u8, name, "Read")) return .{
            .kind = .builtin,
            .category = .read,
            .replay = .read_only,
            .prefetch_safe = true,
        };
        return null;
    }

    fn noName(_: *const anyopaque, _: usize) ?[]const u8 {
        return null;
    }
};

fn smallTestProfile() Profile {
    return .{
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
}

test "Provider reservation failure performs zero external calls" {
    const profile = smallTestProfile();
    const admitted = try preflight(profile, 3300, &.{"x"});
    var controller = Controller.init(std.testing.allocator, profile, admitted);
    var base = TestProvider{ .allocator = std.testing.allocator };
    var decorated = BudgetedProvider{
        .allocator = std.testing.allocator,
        .controller = &controller,
        .base = base.provider(),
    };
    try std.testing.expectError(
        error.CheckpointBudgetExhausted,
        decorated.provider().sendStream(&.{}, null, null, null, null, null, ""),
    );
    try std.testing.expectEqual(@as(u32, 0), base.calls);
    try std.testing.expectEqual(Outcome.budget_exhausted, controller.outcome());
}

test "oversized Provider stream is never released to the agent loop" {
    var profile = smallTestProfile();
    profile.provider_result_cap_bytes = 64;
    const admitted = try preflight(profile, 1000, &.{"x"});
    var controller = Controller.init(std.testing.allocator, profile, admitted);
    var base = TestProvider{
        .allocator = std.testing.allocator,
        .payload_bytes = 65,
    };
    var decorated = BudgetedProvider{
        .allocator = std.testing.allocator,
        .controller = &controller,
        .base = base.provider(),
    };
    var stream = try decorated.provider().sendStream(
        &.{},
        null,
        null,
        null,
        null,
        null,
        "",
    );
    defer stream.deinit();
    try std.testing.expectEqual(@as(?core.api_stream.StreamEvent, null), try stream.next());
    try std.testing.expectEqual(@as(u32, 1), base.calls);
    try std.testing.expectEqual(Outcome.resource_limit, controller.outcome());
}

test "thinking stream is charged as durable payload and freed when over limit" {
    var profile = smallTestProfile();
    profile.provider_result_cap_bytes = 64;
    const admitted = try preflight(profile, 1000, &.{"x"});
    var controller = Controller.init(std.testing.allocator, profile, admitted);
    var base = TestProvider{
        .allocator = std.testing.allocator,
        .payload_bytes = 65,
        .stream_event_kind = .thinking,
    };
    var decorated = BudgetedProvider{
        .allocator = std.testing.allocator,
        .controller = &controller,
        .base = base.provider(),
    };
    var stream = try decorated.provider().sendStream(
        &.{},
        null,
        null,
        null,
        null,
        null,
        "",
    );
    defer stream.deinit();
    try std.testing.expectEqual(@as(?core.api_stream.StreamEvent, null), try stream.next());
    try std.testing.expectEqual(@as(u32, 1), base.calls);
    try std.testing.expectEqual(Outcome.resource_limit, controller.outcome());
}

test "Tool reservation failure skips dispatch and oversized payload is replaced" {
    const profile = smallTestProfile();
    var denied_controller = Controller.init(std.testing.allocator, profile, .{
        .input_delta_bytes = 0,
        .projected_usage_bytes = 3800,
        .minimum_required_bytes = 3800,
    });
    var denied_base = TestDispatcher{ .payload_bytes = 1 };
    var denied_tools = ToolEnvironment{
        .controller = &denied_controller,
        .base = .{
            .definitions = &.{},
            .dispatcher = denied_base.dispatcher(),
        },
    };
    const decorated_dispatcher = denied_tools.surface().dispatcher;
    try std.testing.expect(decorated_dispatcher.prefetchSafe("Read"));
    try std.testing.expect(decorated_dispatcher.isBuiltin("Read"));
    try std.testing.expect(!decorated_dispatcher.isHostSync("Read"));
    try std.testing.expectEqual(core.tool_context.ToolCategory.read, decorated_dispatcher.category("Read").?);
    try std.testing.expectEqual(core.tools.ReplayDeclaration.read_only, decorated_dispatcher.replayDeclaration("Read"));
    try std.testing.expect(!decorated_dispatcher.isBuiltin("unknown"));
    try std.testing.expect(decorated_dispatcher.category("unknown") == null);
    const tool_ctx = core.tool_context.ToolContext{
        .allocator = std.testing.allocator,
    };
    var denied = try denied_tools.surface().dispatcher.dispatch(
        &tool_ctx,
        "Read",
        "{}",
    );
    defer denied.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), denied_base.calls);

    var limited_profile = profile;
    limited_profile.tool_result_cap_bytes = 16;
    var limited_controller = Controller.init(std.testing.allocator, limited_profile, .{
        .input_delta_bytes = 0,
        .projected_usage_bytes = 1000,
        .minimum_required_bytes = 1000,
    });
    var limited_base = TestDispatcher{ .payload_bytes = 17 };
    var limited_tools = ToolEnvironment{
        .controller = &limited_controller,
        .base = .{
            .definitions = &.{},
            .dispatcher = limited_base.dispatcher(),
        },
    };
    var limited = try limited_tools.surface().dispatcher.dispatch(
        &tool_ctx,
        "Read",
        "{}",
    );
    defer limited.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), limited_base.calls);
    try std.testing.expectEqual(Outcome.resource_limit, limited_controller.outcome());
    try std.testing.expectEqualStrings(
        RESOURCE_LIMIT_MARKER,
        limited.host_failed.?,
    );
}

test "oversized inline Tool result is promoted before the AgentCore raw cap" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    const profile = Profile{
        .hard_bytes = 64 * 1024,
        .soft_bytes = 48 * 1024,
        .input_cap_bytes = 8 * 1024,
        .provider_request_cap_bytes = 8 * 1024,
        .provider_result_cap_bytes = 8 * 1024,
        .tool_result_cap_bytes = 4 * 1024,
        .mcp_result_cap_bytes = 4 * 1024,
        .audit_reserve_bytes = 256,
        .terminal_reserve_bytes = 256,
    };
    var controller = Controller.init(allocator, profile, .{
        .input_delta_bytes = 0,
        .projected_usage_bytes = 256,
        .minimum_required_bytes = 256,
    });
    var base = TestDispatcher{ .payload_bytes = 16 * 1024 };
    var environment = ToolEnvironment{
        .controller = &controller,
        .base = .{ .definitions = &.{}, .dispatcher = base.dispatcher() },
    };
    const tool_ctx = core.tool_context.ToolContext{
        .allocator = allocator,
        .artifact_root = root,
    };
    var outcome = try environment.surface().dispatcher.dispatch(&tool_ctx, "HostLarge", "{}");
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome == .ok);
    try std.testing.expect(outcome.ok == .artifact);
    try std.testing.expectEqual(Outcome.none, controller.outcome());
    var rendered = try outcome.ok.render(allocator);
    defer rendered.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes, "ReadArtifact") != null);
    var recovered = try core.tool_result_artifact.readChunk(
        allocator,
        root,
        outcome.ok.artifact.stored.id(),
        0,
        16 * 1024,
    );
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 16 * 1024), recovered.bytes.len);
}

test "artifact envelope allocation failure releases the Tool reservation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const receipt = try core.tool_result_artifact.persist(allocator, root, "render-oom");

    const ArtifactDispatcher = struct {
        receipt: core.tool_result_artifact.Receipt,

        fn dispatch(
            raw: *const anyopaque,
            _: *const core.tool_context.ToolContext,
            _: []const u8,
            _: []const u8,
        ) anyerror!core.tools.ToolDispatchOutcome {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            return .{ .ok = core.tools.ToolResultBody.fromCompletedSpool(
                .{ .receipt = self.receipt, .preview = .{} },
                .text_utf8,
            ) };
        }

        fn metadata(_: *const anyopaque, _: []const u8) ?core.tools.ToolMeta {
            return .{
                .kind = .external,
                .category = .execute,
                .replay = .never,
                .prefetch_safe = false,
            };
        }

        fn noName(_: *const anyopaque, _: usize) ?[]const u8 {
            return null;
        }

        fn dispatcher(self: *const @This()) core.tools.ToolDispatcher {
            return .{
                .ctx = self,
                .dispatchFn = dispatch,
                .metadataFn = metadata,
                .nameAtFn = noName,
            };
        }
    };

    var artifact_dispatcher = ArtifactDispatcher{ .receipt = receipt };
    const profile = smallTestProfile();
    var controller = Controller.init(allocator, profile, .{
        .input_delta_bytes = 0,
        .projected_usage_bytes = 1000,
        .minimum_required_bytes = 1000,
    });
    var environment = ToolEnvironment{
        .controller = &controller,
        .base = .{ .definitions = &.{}, .dispatcher = artifact_dispatcher.dispatcher() },
    };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const tool_ctx = core.tool_context.ToolContext{
        .allocator = failing.allocator(),
        .artifact_root = root,
    };
    try std.testing.expectError(
        error.OutOfMemory,
        environment.surface().dispatcher.dispatch(&tool_ctx, "Artifact", "{}"),
    );
    try std.testing.expectEqual(@as(u64, 0), controller.reserved_bytes);
    try std.testing.expectEqual(Outcome.none, controller.outcome());
}

test "bounded replacement allocation failure does not double-free the settled Tool outcome" {
    const allocator = std.testing.allocator;
    var profile = smallTestProfile();
    profile.tool_result_cap_bytes = 16;
    var controller = Controller.init(allocator, profile, .{
        .input_delta_bytes = 0,
        .projected_usage_bytes = 1000,
        .minimum_required_bytes = 1000,
    });
    var base = TestDispatcher{ .payload_bytes = 17 };
    var environment = ToolEnvironment{
        .controller = &controller,
        .base = .{ .definitions = &.{}, .dispatcher = base.dispatcher() },
    };
    // Allocation zero constructs the original inline body. Allocation one is
    // the bounded resource-limit replacement after settleSuccess rejects it.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    const tool_ctx = core.tool_context.ToolContext{ .allocator = failing.allocator() };
    try std.testing.expectError(
        error.OutOfMemory,
        environment.surface().dispatcher.dispatch(&tool_ctx, "TooLarge", "{}"),
    );
    try std.testing.expectEqual(@as(u64, 0), controller.reserved_bytes);
    try std.testing.expectEqual(Outcome.resource_limit, controller.outcome());
}

test "MCP reservation failure occurs before connector invocation" {
    const fixture = @import("mcp_test_support.zig");
    const mcp_catalog = @import("mcp_catalog.zig");
    var server = fixture.Server{};
    const binding = [_]u8{0x94} ** 32;
    const specs = [_]mcp_catalog.ServerSpec{.{
        .binding = binding,
        .namespace = "weather",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "budget-test", .version = "1" },
    }};
    var manager = try mcp_catalog.Manager.init(
        std.testing.allocator,
        &specs,
        .{},
    );
    defer manager.deinit();
    _ = try manager.refresh();
    const snapshot = try manager.retainCurrent();
    defer snapshot.release();
    var view = try mcp_session.View.init(
        std.testing.allocator,
        snapshot,
        &.{.{
            .server_binding_identity = binding,
            .tool_name = "weather",
        }},
        .fresh,
    );
    defer view.deinit();
    var builtin = TestDispatcher{ .payload_bytes = 1 };
    var mcp_environment = try mcp_session.Environment.init(
        std.testing.allocator,
        &view,
        &.{},
        builtin.dispatcher(),
        null,
    );
    defer mcp_environment.deinit();
    const profile = smallTestProfile();
    var controller = Controller.init(std.testing.allocator, profile, .{
        .input_delta_bytes = 0,
        .projected_usage_bytes = 3800,
        .minimum_required_bytes = 3800,
    });
    var budgeted = ToolEnvironment{
        .controller = &controller,
        .base = mcp_environment.surface(),
    };
    const tool_ctx = core.tool_context.ToolContext{
        .allocator = std.testing.allocator,
    };
    var outcome = try budgeted.surface().dispatcher.dispatch(
        &tool_ctx,
        view.entries[0].model_name,
        "{\"city\":\"Paris\"}",
    );
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), server.calls);
    try std.testing.expectEqual(Outcome.budget_exhausted, controller.outcome());
}

test "oversized MCP success is promoted to the shared recoverable artifact plane" {
    const allocator = std.testing.allocator;
    const fixture = @import("mcp_test_support.zig");
    const mcp_catalog = @import("mcp_catalog.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    var server = fixture.Server{ .result_padding_bytes = 16 * 1024 };
    const binding = [_]u8{0x95} ** 32;
    const specs = [_]mcp_catalog.ServerSpec{.{
        .binding = binding,
        .namespace = "weather",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "budget-test", .version = "1" },
    }};
    var manager = try mcp_catalog.Manager.init(allocator, &specs, .{});
    defer manager.deinit();
    _ = try manager.refresh();
    const snapshot = try manager.retainCurrent();
    defer snapshot.release();
    var view = try mcp_session.View.init(
        allocator,
        snapshot,
        &.{.{
            .server_binding_identity = binding,
            .tool_name = "weather",
        }},
        .fresh,
    );
    defer view.deinit();
    var builtin = TestDispatcher{ .payload_bytes = 1 };
    var mcp_environment = try mcp_session.Environment.init(
        allocator,
        &view,
        &.{},
        builtin.dispatcher(),
        null,
    );
    defer mcp_environment.deinit();
    const profile = Profile{
        .hard_bytes = 64 * 1024,
        .soft_bytes = 48 * 1024,
        .input_cap_bytes = 8 * 1024,
        .provider_request_cap_bytes = 8 * 1024,
        .provider_result_cap_bytes = 8 * 1024,
        .tool_result_cap_bytes = 4 * 1024,
        .mcp_result_cap_bytes = 4 * 1024,
        .audit_reserve_bytes = 256,
        .terminal_reserve_bytes = 256,
    };
    var controller = Controller.init(allocator, profile, .{
        .input_delta_bytes = 0,
        .projected_usage_bytes = 256,
        .minimum_required_bytes = 256,
    });
    var budgeted = ToolEnvironment{
        .controller = &controller,
        .base = mcp_environment.surface(),
    };
    const tool_ctx = core.tool_context.ToolContext{
        .allocator = allocator,
        .artifact_root = root,
    };
    var outcome = try budgeted.surface().dispatcher.dispatch(
        &tool_ctx,
        view.entries[0].model_name,
        "{\"city\":\"Paris\"}",
    );
    defer outcome.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), server.calls);
    try std.testing.expect(outcome == .ok);
    try std.testing.expect(outcome.ok == .artifact);
    try std.testing.expectEqual(Outcome.none, controller.outcome());
    var recovered = try core.tool_result_artifact.readChunk(
        allocator,
        root,
        outcome.ok.artifact.stored.id(),
        0,
        32 * 1024,
    );
    defer recovered.deinit();
    try std.testing.expect(recovered.bytes.len > profile.mcp_result_cap_bytes);
    try std.testing.expect(std.mem.indexOf(u8, recovered.bytes, "structuredContent") != null);
}

test "exact admission boundary and soft recommendation are deterministic" {
    const profile = smallTestProfile();
    const input_delta = try checkpoint.encodedTextMessageBytes("x");
    const reserve = try profile.minimumRunReserve();
    const boundary_usage = profile.hard_bytes - reserve - input_delta;
    const admitted = try preflight(profile, boundary_usage, &.{"x"});
    try std.testing.expectEqual(profile.hard_bytes, admitted.minimum_required_bytes);
    try std.testing.expectError(
        error.BudgetRequired,
        preflight(profile, boundary_usage + 1, &.{"x"}),
    );
    var state = try SessionState.init(profile);
    try state.updateUsage(profile.soft_bytes - 1);
    try std.testing.expect(!state.describe().compaction_recommended);
    try state.updateUsage(profile.soft_bytes);
    try std.testing.expect(state.describe().compaction_recommended);
}

test "canonicalRequestBytes: 非 claude vision 模型带图可测量,载荷字节计入" {
    // 此前经 Anthropic 序列化器直算 → gpt-4o 带图报 ImageInputUnsupported,
    // 预算 admission 拒绝 provider 本会接受的请求(review 轮修复,此测试锁定)。
    const allocator = std.testing.allocator;
    const contents = [_]core.types.ApiContent{
        .{ .text = "look" },
        .{ .image = .{ .media_type = "image/png", .data = "QUJDREVGRw==" } },
    };
    const messages = [_]core.types.ApiMessage{.{ .role = .user, .content = &contents }};
    const with_image = try canonicalRequestBytes(allocator, "gpt-4o", 1024, &messages, null, null, null, true);

    const text_only = [_]core.types.ApiContent{.{ .text = "look" }};
    const text_messages = [_]core.types.ApiMessage{.{ .role = .user, .content = &text_only }};
    const without_image = try canonicalRequestBytes(allocator, "gpt-4o", 1024, &text_messages, null, null, null, true);

    // 真实载荷字节(base64+MIME+信封)计入测量:带图严格大于纯文本 + 载荷长度。
    try std.testing.expect(with_image > without_image + 12);
}

test "canonicalRequestBytes: 纯文本路由的图片工具结果按占位符计,不按 base64 加回" {
    // review 轮 16 Medium:纯文本路由(deepseek-chat/glm-5.2)真实 wire 是短占位符,
    // 预检却把原始 base64 长度加回 → 四张接近 16 MiB 允量的图误报 budget exhausted。
    const allocator = std.testing.allocator;
    const data = "A" ** 4096;
    const image_result = "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"" ++ data ++ "\"}";
    const contents = [_]core.types.ApiContent{
        .{ .tool_result = .{ .tool_use_id = "toolu_1", .content = image_result, .is_error = false } },
    };
    const messages = [_]core.types.ApiMessage{.{ .role = .user, .content = &contents }};
    const text_contents = [_]core.types.ApiContent{
        .{ .tool_result = .{ .tool_use_id = "toolu_1", .content = "[image tool result]", .is_error = false } },
    };
    const text_messages = [_]core.types.ApiMessage{.{ .role = .user, .content = &text_contents }};

    // 模型名只是估算体里的一个标签(会进序列化字节),三次调用固定同一个,路由标志才是变量。
    const placeholder_only = try canonicalRequestBytes(allocator, "deepseek-chat", 1024, &text_messages, null, null, null, false);
    const text_route = try canonicalRequestBytes(allocator, "deepseek-chat", 1024, &messages, null, null, null, false);
    const vision_route = try canonicalRequestBytes(allocator, "deepseek-chat", 1024, &messages, null, null, null, true);

    // 纯文本路由:估算就是投影后的占位符请求,一个字节的 base64 都不加回。
    try std.testing.expectEqual(placeholder_only, text_route);
    // 原生收图的路由:整条图片结果的 JSON 长度加回。
    try std.testing.expectEqual(text_route + image_result.len, vision_route);
}
