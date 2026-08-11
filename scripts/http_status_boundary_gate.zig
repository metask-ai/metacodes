const std = @import("std");

const boundary_path = "src/api/http_status.zig";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = std.process.Args.iterateAllocator(init.minimal.args, allocator) catch
        return error.InvalidArguments;
    defer args.deinit();
    _ = args.next();
    const root_path = args.next() orelse ".";
    if (args.next() != null) return error.InvalidArguments;

    var root = try std.Io.Dir.cwd().openDir(init.io, root_path, .{});
    defer root.close(init.io);

    var violations: usize = 0;
    inline for (.{ "src", "tests" }) |name| {
        var child = try root.openDir(init.io, name, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        defer child.close(init.io);
        try scanTree(allocator, init.io, child, name, &violations);
    }
    if (violations != 0) return error.HttpStatusBoundaryViolation;
}

fn scanTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    prefix: []const u8,
    violations: *usize,
) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var child = try dir.openDir(io, entry.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                });
                defer child.close(io);
                const child_prefix = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
                try scanTree(allocator, io, child, child_prefix, violations);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
                if (std.mem.eql(u8, path, boundary_path)) continue;
                const source_bytes = try dir.readFileAlloc(
                    io,
                    entry.name,
                    allocator,
                    .limited(16 * 1024 * 1024),
                );
                const source = try allocator.dupeZ(u8, source_bytes);
                violations.* += validateSource(path, source, true);
            },
            else => {},
        }
    }
}

const Pattern = struct {
    tokens: []const []const u8,
    message: []const u8,
};

const patterns = [_]Pattern{
    .{
        .tokens = &.{ "head", ".", "status" },
        .message = "wire response status must be captured at the unique boundary",
    },
    .{
        .tokens = &.{ "std", ".", "http", ".", "Status" },
        .message = "std.http.Status must not escape the unique boundary",
    },
    .{
        .tokens = &.{ "http", ".", "Status" },
        .message = "http.Status must not escape the unique boundary",
    },
    .{
        .tokens = &.{ "@tagName", "(", "status", ")" },
        .message = "status names must be captured safely at the unique boundary",
    },
};

fn validateSource(path: []const u8, source: [:0]const u8, report: bool) usize {
    var tokenizer = std.zig.Tokenizer.init(source);
    var recent: [5]std.zig.Token = undefined;
    var recent_len: usize = 0;
    var violations: usize = 0;

    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (recent_len < recent.len) {
            recent[recent_len] = token;
            recent_len += 1;
        } else {
            for (0..recent.len - 1) |i| recent[i] = recent[i + 1];
            recent[recent.len - 1] = token;
        }

        for (patterns) |pattern| {
            if (pattern.tokens.len > recent_len) continue;
            const start = recent_len - pattern.tokens.len;
            var matches = true;
            for (pattern.tokens, 0..) |expected, i| {
                const actual = source[recent[start + i].loc.start..recent[start + i].loc.end];
                if (!std.mem.eql(u8, actual, expected)) {
                    matches = false;
                    break;
                }
            }
            if (!matches) continue;

            // `http.Status` is a suffix of `std.http.Status`; report the more specific rule once.
            if (pattern.tokens.len == 3 and start >= 2) {
                const maybe_std = source[recent[start - 2].loc.start..recent[start - 2].loc.end];
                const maybe_period = source[recent[start - 1].loc.start..recent[start - 1].loc.end];
                if (std.mem.eql(u8, maybe_std, "std") and std.mem.eql(u8, maybe_period, ".")) continue;
            }

            const first = recent[start];
            const line = 1 + std.mem.count(u8, source[0..first.loc.start], "\n");
            if (report) std.debug.print("{s}:{d}: {s}\n", .{ path, line, pattern.message });
            violations += 1;
        }
    }
    return violations;
}

test "gate ignores comments and strings but rejects executable raw status use" {
    const inert_source =
        \\// response.head.status and std.http.Status
        \\const text = "@tagName(status)";
    ;
    try std.testing.expectEqual(
        @as(usize, 0),
        validateSource("src/example.zig", inert_source, false),
    );
    try std.testing.expectEqual(@as(usize, 1), validateSource(
        "src/example.zig",
        "const code = response.head.status;",
        false,
    ));
    try std.testing.expectEqual(@as(usize, 1), validateSource(
        "src/example.zig",
        "fn inspect(head: anytype) void { const status = head.status; }",
        false,
    ));
    try std.testing.expectEqual(@as(usize, 1), validateSource(
        "src/example.zig",
        "fn f(status: std.http.Status) void {}",
        false,
    ));
    try std.testing.expectEqual(@as(usize, 1), validateSource(
        "src/example.zig",
        "const name = @tagName(status);",
        false,
    ));
}
