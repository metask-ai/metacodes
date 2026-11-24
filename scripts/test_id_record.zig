const builtin = @import("builtin");
const std = @import("std");

pub const dir_env = "METACODES_TEST_IDS_DIR";

pub const Status = enum { pass, skip, fail };

pub const Record = struct {
    file: std.Io.File,
    writer: std.Io.File.Writer,

    pub fn write(record: *Record, status: Status, name: []const u8) void {
        record.writer.interface.print("{t}\t{s}\n", .{ status, name }) catch @panic("failed to write a test ID");
        record.writer.interface.flush() catch @panic("failed to write a test ID");
    }

    pub fn close(record: *Record, io: std.Io) void {
        record.file.close(io);
    }
};

pub fn fileName(allocator: std.mem.Allocator, argv0: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "zig-{s}-{t}{s}.tsv", .{ std.fs.path.stem(argv0), builtin.mode, suffix });
}

pub fn open(record: *Record, buffer: []u8, io: std.Io, environ: std.process.Environ, file_name: []const u8) bool {
    const allocator = std.heap.page_allocator;
    const dir_path = environ.getAlloc(allocator, dir_env) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        else => std.debug.panic("cannot read {s}: {t}", .{ dir_env, err }),
    };
    defer allocator.free(dir_path);
    if (dir_path.len == 0) return false;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch |err|
        std.debug.panic("cannot open {s}={s}: {t}", .{ dir_env, dir_path, err });
    defer dir.close(io);
    const file = dir.createFile(io, file_name, .{ .exclusive = true }) catch |err|
        std.debug.panic("cannot create {s} in {s}: {t}", .{ file_name, dir_path, err });
    record.* = .{ .file = file, .writer = .init(file, io, buffer) };
    return true;
}

test "file names carry the binary, the mode and the suffix" {
    const name = try fileName(std.testing.allocator, "/cache/o/abc/metacodes-core-test", "-2of4");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("zig-metacodes-core-test-" ++ @tagName(builtin.mode) ++ "-2of4.tsv", name);
}
