//! Test-only resolver for the staged manually maintained TinyKG binary.
//!
//! Tests never inspect a developer checkout, PATH, or a stale zig-out tree.
//! The build graph selects the checked-in target bundle and wires
//! METACODES_TEST_TINYKG_BIN only after staging succeeds; maintainers may set
//! the same variable explicitly while auditing an override.

const std = @import("std");
const builtin = @import("builtin");

pub fn find(allocator: std.mem.Allocator) ?[]u8 {
    const names = [_][:0]const u8{
        "METACODES_TEST_TINYKG_BIN",
        "METACODES_KG_BIN",
    };
    for (names) |name| {
        const raw = std.c.getenv(name.ptr) orelse continue;
        const path = std.mem.span(raw);
        if (isExecutable(path)) return allocator.dupe(u8, path) catch null;
        return null;
    }
    return null;
}

fn isExecutable(path: []const u8) bool {
    var buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buffer.len) return false;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    const mode: c_uint = if (builtin.os.tag == .windows) std.c.F_OK else std.c.X_OK;
    return std.c.access(buffer[0..path.len :0].ptr, mode) == 0;
}

test "missing staged TinyKG test input is absent" {
    // The production assertion is the lack of any filesystem/PATH fallback in
    // find(). Environment-bearing positive behavior is covered by component
    // L2 when build.zig wires the attested binary.
    if (std.c.getenv("METACODES_TEST_TINYKG_BIN") == null and
        std.c.getenv("METACODES_KG_BIN") == null)
    {
        try std.testing.expect(find(std.testing.allocator) == null);
    }
}
