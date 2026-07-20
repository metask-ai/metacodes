//! Typed Zig convenience layer shipped beside the binary ABI. No AgentCore
//! implementation source is imported (source-free binary consumption).

pub const types = @import("metask_agentcore_types");
pub const protocol = @import("metask_agentcore_protocol");

pub const Status = types.Status;
pub const StopReason = types.StopReason;
pub const CoreEvent = protocol.CoreEvent;
pub const DecodedCoreEvent = protocol.DecodedCoreEvent;
pub const UnknownCoreEvent = protocol.UnknownCoreEvent;
pub const UiRequest = protocol.UiRequest;
pub const UiResponse = protocol.UiResponse;
pub const ParsedCoreEvent = protocol.ParsedCoreEvent;
pub const ParsedUiRequest = protocol.ParsedUiRequest;
pub const DecodeError = protocol.DecodeError;
pub const EncodeError = protocol.EncodeError;
pub const decodeCoreEvent = protocol.decodeCoreEvent;
pub const decodeUiRequest = protocol.decodeUiRequest;
pub const encodeUiResponse = protocol.encodeUiResponse;

pub extern fn metask_agentcore_get_api(requested_abi: u32) callconv(.c) ?*const anyopaque;

pub fn bytesView(bytes: []const u8) types.BytesViewV1 {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

pub fn borrowedBytes(view: types.BytesViewV1) error{InvalidBytesView}![]const u8 {
    const len = std.math.cast(usize, view.len) orelse return error.InvalidBytesView;
    if (len == 0) return "";
    return (view.ptr orelse return error.InvalidBytesView)[0..len];
}

pub const RunContext = struct {
    session: *types.SessionHandle,
    run_id: u64,
    session_id: []const u8,
};

/// Validation order is part of the ABI defense: bound the Host-provided length
/// before constructing a slice from its pointer.
pub fn validateRunContext(raw: ?*const types.RunContextV1) error{InvalidRunContext}!RunContext {
    const run = raw orelse return error.InvalidRunContext;
    if (run.struct_size != @sizeOf(types.RunContextV1) or run.reserved0 != 0 or
        run.session == null or run.run_id == 0 or !allZero(run.reserved))
        return error.InvalidRunContext;
    if (run.session_id.len == 0 or run.session_id.len > types.MAX_SESSION_ID_BYTES_V1)
        return error.InvalidRunContext;
    const len: usize = @intCast(run.session_id.len);
    const bytes = (run.session_id.ptr orelse return error.InvalidRunContext)[0..len];
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidRunContext;
    return .{ .session = run.session.?, .run_id = run.run_id, .session_id = bytes };
}

pub const Api = struct {
    raw: *const types.ApiV1,

    pub fn discover() error{UnsupportedAbi}!Api {
        const ptr = metask_agentcore_get_api(types.ABI_VERSION_V1) orelse return error.UnsupportedAbi;
        return validate(@ptrCast(@alignCast(ptr)));
    }

    pub fn validate(raw: *const types.ApiV1) error{UnsupportedAbi}!Api {
        // Offsets 0..7 are the stable discovery prefix. Never read revision or
        // later fields from a legacy 104-byte table before the exact size check.
        if (raw.struct_size != @sizeOf(types.ApiV1) or raw.abi_version != types.ABI_VERSION_V1)
            return error.UnsupportedAbi;
        if (raw.abi_revision != types.ABI_REVISION or raw.reserved0 != 0 or
            raw.capabilities & types.REQUIRED_CAPABILITIES_V1 != types.REQUIRED_CAPABILITIES_V1 or
            !allZero(raw.reserved) or
            raw.runtime_create == null or raw.runtime_destroy == null or raw.session_create == null or
            raw.session_destroy == null or raw.session_run == null or raw.session_abort == null or raw.buffer_release == null)
            return error.UnsupportedAbi;
        return .{ .raw = raw };
    }

    pub fn runtimeCreate(self: Api) types.RuntimeCreateFnV1 {
        return self.raw.runtime_create.?;
    }
    pub fn runtimeDestroy(self: Api) types.RuntimeDestroyFnV1 {
        return self.raw.runtime_destroy.?;
    }
    pub fn sessionCreate(self: Api) types.SessionCreateFnV1 {
        return self.raw.session_create.?;
    }
    pub fn sessionDestroy(self: Api) types.SessionDestroyFnV1 {
        return self.raw.session_destroy.?;
    }
    pub fn sessionRun(self: Api) types.SessionRunFnV1 {
        return self.raw.session_run.?;
    }
    pub fn sessionAbort(self: Api) types.SessionAbortFnV1 {
        return self.raw.session_abort.?;
    }
    pub fn bufferRelease(self: Api) types.BufferReleaseFnV1 {
        return self.raw.buffer_release.?;
    }
};

fn allZero(values: anytype) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

const std = @import("std");

test "SDK rejects incomplete API tables" {
    var raw: types.ApiV1 = std.mem.zeroes(types.ApiV1);
    try std.testing.expectError(error.UnsupportedAbi, Api.validate(&raw));
}

test "RunContext validator bounds length before pointer slicing" {
    var session_byte: u8 = 0;
    const session: *types.SessionHandle = @ptrCast(&session_byte);
    var run = std.mem.zeroes(types.RunContextV1);
    run.struct_size = @sizeOf(types.RunContextV1);
    run.session = session;
    run.run_id = 9;
    run.session_id = .{ .ptr = null, .len = std.math.maxInt(u64) };
    try std.testing.expectError(error.InvalidRunContext, validateRunContext(&run));

    const id = "0123456789abcdef01234567";
    run.session_id = bytesView(id);
    const valid = try validateRunContext(&run);
    try std.testing.expectEqual(@as(u64, 9), valid.run_id);
    try std.testing.expectEqualStrings(id, valid.session_id);
}

test "SDK rejects legacy pre-revision API size from the stable prefix" {
    const LegacyApi = extern struct {
        struct_size: u32,
        abi_version: u32,
        capabilities: u64,
        tail: [88]u8,
    };
    var legacy = std.mem.zeroes(LegacyApi);
    legacy.struct_size = 104;
    legacy.abi_version = types.ABI_VERSION_V1;
    const raw: *const types.ApiV1 = @ptrCast(&legacy);
    try std.testing.expectError(error.UnsupportedAbi, Api.validate(raw));
}
