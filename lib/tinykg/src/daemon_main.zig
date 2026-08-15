const implementation = @import("daemon/main.zig");

pub fn main(init: @import("std").process.Init) !void {
    return implementation.main(init);
}

test {
    _ = implementation;
}
