//! metacodes plugin contract and Runtime composition surface.

pub const contract = @import("contract.zig");
pub const effect_scope = @import("effect_scope.zig");
pub const first_party = @import("first_party.zig");
pub const manifest = @import("manifest.zig");
pub const process = @import("process.zig");
pub const runtime = @import("runtime.zig");
pub const support = @import("support.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
