const std = @import("std");

/// Invocation-local view of the host environment shared by CLI dispatch and
/// explicitly governed lower-level adapters that honor the same embedded-call
/// snapshot.
///
/// CLI commands are synchronous, so a thread-local, stack-shaped scope keeps
/// independent embedded callers isolated without threading environment
/// plumbing through every command owner. Nested invocations restore the outer
/// map exactly; different host threads never share the pointer.
threadlocal var current_map: ?*const std.process.Environ.Map = null;

pub const Scope = struct {
    previous: ?*const std.process.Environ.Map,
    active: bool = true,

    pub fn deinit(self: *Scope) void {
        std.debug.assert(self.active);
        current_map = self.previous;
        self.active = false;
    }
};

pub fn enter(map: ?*const std.process.Environ.Map) Scope {
    const scope = Scope{ .previous = current_map };
    current_map = map;
    return scope;
}

/// Compatibility hook for the original executable embedding surface. New
/// library callers should prefer the stack-shaped `Invocation.environment`.
pub fn set(map: ?*const std.process.Environ.Map) void {
    current_map = map;
}

pub fn get(name: []const u8) ?[]const u8 {
    const map = current_map orelse return null;
    return map.get(name);
}

pub fn hasMap() bool {
    return current_map != null;
}

test "runtime environment scope restores nested maps" {
    var outer = std.process.Environ.Map.init(std.testing.allocator);
    defer outer.deinit();
    try outer.put("TINYKG_STORE", "outer.kg");

    var inner = std.process.Environ.Map.init(std.testing.allocator);
    defer inner.deinit();
    try inner.put("TINYKG_STORE", "inner.kg");

    try std.testing.expectEqual(@as(?[]const u8, null), get("TINYKG_STORE"));
    var outer_scope = enter(&outer);
    defer outer_scope.deinit();
    try std.testing.expectEqualStrings("outer.kg", get("TINYKG_STORE").?);

    {
        var inner_scope = enter(&inner);
        defer inner_scope.deinit();
        try std.testing.expectEqualStrings("inner.kg", get("TINYKG_STORE").?);
    }
    try std.testing.expectEqualStrings("outer.kg", get("TINYKG_STORE").?);
}

test "runtime environment scope can explicitly hide an outer map" {
    var outer = std.process.Environ.Map.init(std.testing.allocator);
    defer outer.deinit();
    try outer.put("TINYKG_STORE", "outer.kg");

    var outer_scope = enter(&outer);
    defer outer_scope.deinit();
    {
        var empty_scope = enter(null);
        defer empty_scope.deinit();
        try std.testing.expectEqual(@as(?[]const u8, null), get("TINYKG_STORE"));
    }
    try std.testing.expectEqualStrings("outer.kg", get("TINYKG_STORE").?);
}
