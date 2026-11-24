const builtin = @import("builtin");
const std = @import("std");

pub const dir_env = "METACODES_TEST_IDS_DIR";
pub const root_env = "METACODES_TEST_ROOT";
pub const dir_arg = "--test-ids-dir=";

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

pub fn dirFromEnviron(environ: std.process.Environ) ?[]const u8 {
    const dir_path = environ.getAlloc(std.heap.page_allocator, dir_env) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => std.debug.panic("cannot read {s}: {t}", .{ dir_env, err }),
    };
    return if (dir_path.len == 0) null else dir_path;
}

pub fn open(record: *Record, buffer: []u8, io: std.Io, environ: std.process.Environ, dir_path: []const u8, argv0: []const u8, suffix: []const u8) void {
    const file_name = std.fmt.allocPrint(std.heap.page_allocator, "zig-{s}-{t}{s}--{x}.tsv", .{
        std.fs.path.stem(argv0), builtin.mode, suffix, unique(io),
    }) catch @panic("OOM");
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch |err|
        std.debug.panic("cannot open the test ID directory {s}: {t}", .{ dir_path, err });
    defer dir.close(io);
    const file = dir.createFile(io, file_name, .{ .exclusive = true }) catch |err|
        std.debug.panic("cannot create {s} in {s}: {t}", .{ file_name, dir_path, err });
    record.* = .{ .file = file, .writer = .init(file, io, buffer) };
    const root = environ.getAlloc(std.heap.page_allocator, root_env) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return,
        else => std.debug.panic("cannot read {s}: {t}", .{ root_env, err }),
    };
    record.writer.interface.print("root\t{s}\n", .{root}) catch @panic("failed to write a test ID");
}

fn unique(io: std.Io) [8]u8 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return bytes;
}
