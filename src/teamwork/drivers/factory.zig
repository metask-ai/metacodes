//! From a validated seat spec to its `SeatDriver`. The only place that
//! switches on the harness: the runtime builds one `Driver` per seat and
//! never names a harness itself.

const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");
const metacodes = @import("metacodes.zig");
const claude_code = @import("claude_code.zig");

/// Everything any harness needs; a seat uses its own harness's part.
pub const Deps = struct {
    metacodes: metacodes.Deps,
    claude_code: claude_code.Options,
};

/// A seat's driver, by harness. Lives as long as the seat runs; `driver()`
/// borrows it.
pub const Driver = union(types.Harness) {
    metacodes: metacodes.MetacodesDriver,
    claude_code: claude_code.ClaudeCodeDriver,

    pub fn driver(self: *Driver) types.SeatDriver {
        return switch (self.*) {
            inline else => |*impl| impl.driver(),
        };
    }

    pub fn harness(self: *const Driver) types.Harness {
        return std.meta.activeTag(self.*);
    }
};

/// The driver for `spec` (one role of a validated `config.Config`), charging
/// `binding`'s ledger for `binding`'s seat.
pub fn forSeat(spec: *const types.SeatSpec, deps: Deps, binding: common.Binding) Driver {
    return switch (spec.harness) {
        .metacodes => .{ .metacodes = metacodes.MetacodesDriver.init(deps.metacodes, binding) },
        .claude_code => .{ .claude_code = claude_code.ClaudeCodeDriver.init(deps.claude_code, binding) },
    };
}
