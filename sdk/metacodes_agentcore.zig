//! Typed Zig convenience layer shipped beside the binary ABI. No metacodes
//! implementation source is imported (source-free binary consumption).

pub const types = @import("metacodes_agentcore_types");
pub const protocol = @import("metacodes_agentcore_protocol");

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

pub extern fn metacodes_agentcore_get_api(requested_abi: u32) callconv(.c) ?*const anyopaque;

pub fn bytesView(bytes: []const u8) types.BytesViewV1 {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

pub fn borrowedBytes(view: types.BytesViewV1) error{InvalidBytesView}![]const u8 {
    const len = std.math.cast(usize, view.len) orelse return error.InvalidBytesView;
    if (len == 0) return "";
    return (view.ptr orelse return error.InvalidBytesView)[0..len];
}

pub const Api = struct {
    raw: *const types.ApiV1,

    pub fn discover() error{UnsupportedAbi}!Api {
        const ptr = metacodes_agentcore_get_api(types.ABI_VERSION_V1) orelse return error.UnsupportedAbi;
        return validate(@ptrCast(@alignCast(ptr)));
    }

    pub fn validate(raw: *const types.ApiV1) error{UnsupportedAbi}!Api {
        if (raw.struct_size != @sizeOf(types.ApiV1) or raw.abi_version != types.ABI_VERSION_V1 or
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
