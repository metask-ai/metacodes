const std = @import("std");

pub const core = struct {
    pub const agent_session = @import("core/agent_session.zig");
    pub const session_host = @import("core/session_host.zig");
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(core);
}
