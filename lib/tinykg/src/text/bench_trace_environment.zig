const std = @import("std");
const builtin = @import("builtin");
const runtime_environment = @import("../cli/runtime_environment.zig");

/// Resolves Text rebuild tracing through the same invocation-local snapshot as
/// CLI dispatch. Ambient lookup remains the compatibility policy only when no
/// library environment map is active.
pub fn enabled() bool {
    if (runtime_environment.hasMap()) {
        return runtime_environment.get("TINYKG_BENCH_TRACE") != null;
    }
    if (!builtin.link_libc) return false;
    return std.c.getenv("TINYKG_BENCH_TRACE") != null;
}

test "text bench trace environment honors the scoped invocation snapshot" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();

    var scope = runtime_environment.enter(&environment);
    defer scope.deinit();
    try std.testing.expect(!enabled());

    try environment.put("TINYKG_BENCH_TRACE", "1");
    try std.testing.expect(enabled());
}
