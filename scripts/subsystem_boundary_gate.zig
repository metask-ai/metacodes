//! Enforce the two subsystem import boundaries issue #16 relies on.
//!
//! `zig build test:provider` and `test:picker` compile each subsystem from a
//! narrow root and their doc comments claim that a dependency on the transport,
//! the TUI, or `App` would stop them compiling. It would not: the test module's
//! root is `src/`, so *any* file under it is importable, and the only named
//! module either subsystem needs is `platform`. Both gates were decorative —
//! adding `src/client.zig` to the provider root compiles cleanly.
//!
//! The boundary is a source-level rule, so this checks it at the source level:
//! every `@import` in each subsystem must be on that subsystem's allowlist.
//! Widening a list is then a deliberate, reviewable act rather than something
//! that happens by accident because the module graph allowed it.

const std = @import("std");

const Subsystem = struct {
    /// Directory that defines the subsystem, relative to the repository root.
    /// Anything resolving inside it is by definition part of the subsystem.
    dir: []const u8,
    /// Scan nested directories too.
    recursive: bool,
    /// Only these files, when non-empty.
    only: []const []const u8 = &.{},
    /// Named modules the subsystem may depend on.
    modules: []const []const u8,
    /// Files *outside* the subsystem it may reach, as repository-relative
    /// paths. Resolved from the importing file, so `../types.zig` from
    /// `src/provider/ids.zig` and from `src/provider/profiles/metask.zig`
    /// are both checked as the one path they actually name.
    reaches: []const []const u8,
};

const SUBSYSTEMS = [_]Subsystem{
    .{
        // The provider kernel: `std`, `types.zig`, the approved leaf
        // utilities, and the portable platform layer. Not the transport, not
        // a UI.
        .dir = "src/provider",
        .recursive = true,
        .modules = &.{ "std", "builtin", "platform" },
        .reaches = &.{
            "src/types.zig",
            "src/util/model.zig",
            "src/util/pricing.zig",
            "src/util/fs.zig",
            "src/util/file_lock.zig",
            "src/util/json_merge.zig",
            "src/util/json.zig",
        },
    },
    .{
        // The picker is a *client* of the control plane: the provider kernel
        // and the terminal theme, and nothing else. Not `App`, not a client.
        .dir = "src/repl",
        .recursive = false,
        .only = &.{ "model_picker.zig", "model_picker_view.zig" },
        .modules = &.{"std"},
        .reaches = &.{
            "src/repl/model_picker.zig",
            "src/repl/tui/ansi.zig",
            "src/repl/tui/theme.zig",
            "src/provider/ids.zig",
            "src/provider/offer.zig",
            "src/provider/controls.zig",
            "src/provider/selection.zig",
            "src/provider/control_plane.zig",
        },
    },
};

/// Resolve `target` against the directory of `from`, collapsing `..`.
/// Returns null for a named module (no `.zig` suffix).
fn resolve(buffer: []u8, from: []const u8, target: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, target, ".zig")) return null;
    const dir = std.fs.path.dirnamePosix(from) orelse "";
    var len: usize = 0;
    var segments = std.mem.splitScalar(u8, dir, '/');
    var stack: [32][]const u8 = undefined;
    var depth: usize = 0;
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (depth == stack.len) return null;
        stack[depth] = segment;
        depth += 1;
    }
    var parts = std.mem.splitScalar(u8, target, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (depth == 0) return null;
            depth -= 1;
            continue;
        }
        if (depth == stack.len) return null;
        stack[depth] = part;
        depth += 1;
    }
    for (stack[0..depth], 0..) |segment, index| {
        if (index > 0) {
            if (len == buffer.len) return null;
            buffer[len] = '/';
            len += 1;
        }
        if (len + segment.len > buffer.len) return null;
        @memcpy(buffer[len..][0..segment.len], segment);
        len += segment.len;
    }
    return buffer[0..len];
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = std.process.Args.iterateAllocator(init.minimal.args, allocator) catch
        return error.InvalidArguments;
    defer args.deinit();
    _ = args.next();
    const root_path = args.next() orelse ".";

    var root = try std.Io.Dir.cwd().openDir(init.io, root_path, .{});
    defer root.close(init.io);

    var violations: usize = 0;
    for (SUBSYSTEMS) |subsystem| {
        var dir = try root.openDir(init.io, subsystem.dir, .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(init.io);
        try scan(allocator, init.io, dir, subsystem, subsystem.dir, &violations);
    }
    if (violations != 0) return error.SubsystemBoundaryViolation;
}

fn scan(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    subsystem: Subsystem,
    prefix: []const u8,
    violations: *usize,
) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (!subsystem.recursive) continue;
                var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer child.close(io);
                const nested = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
                try scan(allocator, io, child, subsystem, nested, violations);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                if (subsystem.only.len > 0) {
                    var listed = false;
                    for (subsystem.only) |name| {
                        if (std.mem.eql(u8, name, entry.name)) listed = true;
                    }
                    if (!listed) continue;
                }
                const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
                const source = try dir.readFileAlloc(io, entry.name, allocator, .limited(4 * 1024 * 1024));
                try check(source, path, subsystem, violations);
            },
            else => {},
        }
    }
}

fn check(source: []const u8, path: []const u8, subsystem: Subsystem, violations: *usize) !void {
    const needle = "@import(\"";
    var cursor: usize = 0;
    var line: usize = 1;
    var scanned: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, needle)) |found| {
        while (scanned < found) : (scanned += 1) {
            if (source[scanned] == '\n') line += 1;
        }
        const start = found + needle.len;
        const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse break;
        const target = source[start..end];
        if (!allowedImport(path, target, subsystem)) {
            violations.* += 1;
            std.debug.print(
                "{s}:{d}: `{s}` is outside this subsystem's import boundary\n",
                .{ path, line, target },
            );
        }
        cursor = end + 1;
    }
}

fn allowedImport(path: []const u8, target: []const u8, subsystem: Subsystem) bool {
    var buffer: [512]u8 = undefined;
    const resolved = resolve(&buffer, path, target) orelse {
        // No `.zig` suffix: a named module, allowed only if declared.
        for (subsystem.modules) |name| {
            if (std.mem.eql(u8, name, target)) return true;
        }
        return false;
    };
    // Inside the subsystem's own directory is by definition part of it.
    if (std.mem.startsWith(u8, resolved, subsystem.dir) and
        resolved.len > subsystem.dir.len and
        resolved[subsystem.dir.len] == '/') return true;
    for (subsystem.reaches) |allowed| {
        if (std.mem.eql(u8, allowed, resolved)) return true;
    }
    return false;
}

test "a reach outside the subsystem must be listed by name" {
    const subsystem = Subsystem{
        .dir = "src/provider",
        .recursive = true,
        .modules = &.{ "std", "platform" },
        .reaches = &.{"src/types.zig"},
    };
    var violations: usize = 0;

    // Inside the subsystem, from its root and from a nested directory.
    try check("@import(\"ids.zig\")", "src/provider/registry.zig", subsystem, &violations);
    try check("@import(\"../ids.zig\")", "src/provider/profiles/metask.zig", subsystem, &violations);
    try check("@import(\"profiles/metask.zig\")", "src/provider/registry.zig", subsystem, &violations);
    try check("@import(\"std\")", "src/provider/registry.zig", subsystem, &violations);
    try check("@import(\"../types.zig\")", "src/provider/ids.zig", subsystem, &violations);
    try std.testing.expectEqual(@as(usize, 0), violations);

    // The reach this boundary exists to prevent, from both depths — a textual
    // `../` rule admitted the first of these, which is how the transport could
    // have entered the provider kernel unnoticed.
    try check("@import(\"../client.zig\")", "src/provider/registry.zig", subsystem, &violations);
    try std.testing.expectEqual(@as(usize, 1), violations);
    try check("@import(\"../../client.zig\")", "src/provider/profiles/metask.zig", subsystem, &violations);
    try std.testing.expectEqual(@as(usize, 2), violations);
    // An undeclared named module is a dependency too.
    try check("@import(\"hl\")", "src/provider/registry.zig", subsystem, &violations);
    try std.testing.expectEqual(@as(usize, 3), violations);
}

test "paths resolve the way the compiler would read them" {
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "src/provider/ids.zig",
        resolve(&buffer, "src/provider/profiles/metask.zig", "../ids.zig").?,
    );
    try std.testing.expectEqualStrings(
        "src/util/model.zig",
        resolve(&buffer, "src/provider/profiles/metask.zig", "../../util/model.zig").?,
    );
    try std.testing.expectEqualStrings(
        "src/app.zig",
        resolve(&buffer, "src/repl/model_picker.zig", "../app.zig").?,
    );
    // A named module has no path to resolve.
    try std.testing.expect(resolve(&buffer, "src/provider/ids.zig", "platform") == null);
}
