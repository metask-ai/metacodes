const std = @import("std");
const cc = @import("cc");
const pfs = @import("platform").fs;

test "TinyKgD resolution uses env precedence and explicit missing is terminal" {
    const a = std.testing.allocator;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = @import("platform").paths.selfExePath(&exe_buf) orelse return error.SkipZigTest;
    var found = (try cc.kg_client.KgClient.resolveTinykgdBinary(a, .{ .home = "", .domain = "", .env_daemon_bin = exe })).?;
    defer found.deinit(a);
    try std.testing.expectEqual(cc.kg_client.KgClient.BinarySource.env, found.source);
    try std.testing.expectEqualStrings(exe, found.path);
    const missing = try cc.kg_client.KgClient.resolveTinykgdBinary(a, .{
        .home = "",
        .domain = "",
        .env_daemon_bin = "/definitely/missing/tinykgd",
        .exe_dir = "/unused",
    });
    try std.testing.expect(missing == null);
}

test "TinyKgD resolution finds the adjacent staged layout" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    try tmp.dir.createDirPath(std.testing.io, "vendor/tinykg");
    try tmp.dir.createDirPath(std.testing.io, "bin");
    const name = if (@import("builtin").os.tag == .windows) "tinykgd.exe" else "tinykgd";
    const staged = try std.fmt.allocPrint(a, "{s}/vendor/tinykg/{s}", .{ root, name });
    defer a.free(staged);
    const staged_z = try a.dupeZ(u8, staged);
    defer a.free(staged_z);
    const fd = pfs.open(staged_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o755));
    try std.testing.expect(fd >= 0);
    _ = pfs.close(fd);
    const exe_dir = try std.fmt.allocPrint(a, "{s}/bin", .{root});
    defer a.free(exe_dir);
    var found = (try cc.kg_client.KgClient.resolveTinykgdBinary(a, .{ .home = root, .domain = "d", .env_daemon_bin = "", .exe_dir = exe_dir })).?;
    defer found.deinit(a);
    try std.testing.expectEqual(cc.kg_client.KgClient.BinarySource.adjacent, found.source);
    try std.testing.expectEqualStrings(staged, found.path);
}
