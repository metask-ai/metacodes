//! L2 组件测试:ReadState staleness 双判(mtime + content_hash)+ 线程安全(批1 对齐 cc)。
//!
//! 对齐 Claude Code FileEdit:mtime 变但内容没变(云同步/杀软改 mtime)→ 不算 stale 放行。
//! 并发:批1 工具并发后 Read 在其它线程 record,record/get 须线程安全。

const std = @import("std");
const cc = @import("cc");
const pfs = @import("platform").fs; // 可移植文件 IO(std.c.open 的 O 在 Windows 是 void)

const ReadState = cc.core_read_state.ReadState;

fn writeFile(path: [*:0]const u8, content: []const u8) void {
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (fd < 0) return;
    defer pfs.close(fd);
    _ = pfs.write(fd, content);
}

test "L2 read_state: hashFileContent 一致 + 内容变则哈希变" {
    var dir_buf: [512]u8 = undefined;
    const dir = cc.util_fs.testing.perPidDir(&dir_buf, "cc-zig-rs");
    _ = std.c.mkdir(dir.ptr, 0o755);
    defer _ = std.c.rmdir(dir.ptr);
    var p_buf: [512]u8 = undefined;
    const p = try std.fmt.bufPrintZ(&p_buf, "{s}/hash.txt", .{dir});
    writeFile(p.ptr, "hello world");
    defer _ = std.c.unlink(p.ptr);
    const h1 = cc.core_read_state.hashFileContent(p);
    const h2 = cc.core_read_state.hashFileContent(p);
    try std.testing.expectEqual(h1, h2);
    writeFile(p.ptr, "hello WORLD");
    const h3 = cc.core_read_state.hashFileContent(p);
    try std.testing.expect(h1 != h3);
}

test "L2 read_state: recordHashed 存取 content_hash" {
    const a = std.testing.allocator;
    var rs = ReadState.init(a);
    defer rs.deinit();
    try rs.recordHashed("/x/y", 100, 11, 0xABCD);
    const e = rs.get("/x/y") orelse return error.NotFound;
    try std.testing.expectEqual(@as(i128, 100), e.mtime_ns);
    try std.testing.expectEqual(@as(u64, 0xABCD), e.content_hash);
    // 未记过的 path → null
    try std.testing.expect(rs.get("/no") == null);
}

test "L2 read_state: 并发 record 不崩不丢(多线程)" {
    const a = std.testing.allocator;
    var rs = ReadState.init(a);
    defer rs.deinit();

    const Worker = struct {
        fn run(state: *ReadState, base: usize) void {
            var buf: [32]u8 = undefined;
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                const path = std.fmt.bufPrint(&buf, "/p/{d}-{d}", .{ base, i }) catch return;
                state.recordHashed(path, @intCast(base + i), 1, @intCast(i)) catch {};
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &rs, k * 1000 });
    for (&threads) |t| t.join();

    // 4 线程 × 50 = 200 条都在
    var found: usize = 0;
    var buf: [32]u8 = undefined;
    for (0..4) |k| {
        for (0..50) |i| {
            const path = std.fmt.bufPrint(&buf, "/p/{d}-{d}", .{ k * 1000, i }) catch continue;
            if (rs.get(path) != null) found += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 200), found);
}
