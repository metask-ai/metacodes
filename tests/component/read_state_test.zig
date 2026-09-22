//! L2 组件测试:ReadState staleness 双判(mtime + content_hash)+ 线程安全(批1 对齐 cc)。
//!
//! 对齐 Claude Code FileEdit:mtime 变但内容没变(云同步/杀软改 mtime)→ 不算 stale 放行。
//! 并发:批1 工具并发后 Read 在其它线程 record,record/get 须线程安全。

const std = @import("std");
const cc = @import("cc");
const pfs = @import("platform").fs; // 可移植文件 IO(std.c.open 的 O 在 Windows 是 void)

const ReadState = cc.core_read_state.ReadState;

/// Fixture I/O must fail the test, not fall through. The historical helper swallowed a
/// failed open, so an unwritable fixture path collapsed both hashes to the "unreadable"
/// sentinel 0 and the test reported a hash bug (`h1 != h3` false) instead of the real
/// cause. Print what the CRT saw so a CI log carries the evidence.
fn writeFile(path: [*:0]const u8, content: []const u8) !void {
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (fd < 0) return fixtureFailure("open", path);
    defer pfs.close(fd);
    const n = pfs.write(fd, content);
    if (n < 0 or @as(usize, @intCast(n)) != content.len) return fixtureFailure("write", path);
}

fn fixtureFailure(op: []const u8, path: [*:0]const u8) error{FixtureIoFailed} {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd: []const u8 = if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |raw|
        std.mem.span(@as([*:0]const u8, @ptrCast(raw)))
    else
        "?";
    std.debug.print(
        "read_state fixture: {s} failed path={s} errno={d} cwd={s}\n",
        .{ op, path, std.c._errno().*, cwd },
    );
    return error.FixtureIoFailed;
}

test "L2 read_state: hashFileContent 一致 + 内容变则哈希变" {
    // Per-process directory under the platform temp root (util/fs.zig testing.tmpRoot):
    // absolute with a drive letter on Windows. A bare `/tmp/...` literal is resolved by
    // the Windows CRT against the process's current drive and is shared by every
    // parallel shard; this test has no business depending on either.
    var dir_buf: [512]u8 = undefined;
    const dir = cc.util_fs.testing.perPidDir(&dir_buf, "cc-zig-read-state");
    if (std.c.mkdir(dir.ptr, 0o755) != 0 and !pfs.exists(dir.ptr)) return fixtureFailure("mkdir", dir.ptr);
    defer _ = std.c.rmdir(dir.ptr);
    var path_buf: [512]u8 = undefined;
    const p = try std.fmt.bufPrintZ(&path_buf, "{s}/cc-rs-hash.txt", .{dir});
    try writeFile(p, "hello world");
    defer _ = std.c.unlink(p);
    const h1 = cc.core_read_state.hashFileContent(p);
    const h2 = cc.core_read_state.hashFileContent(p);
    try std.testing.expect(h1 != 0); // 0 is hashFileContent's "unreadable" sentinel, not a hash
    try std.testing.expectEqual(h1, h2);
    try writeFile(p, "hello WORLD");
    const h3 = cc.core_read_state.hashFileContent(p);
    try std.testing.expect(h3 != 0);
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
