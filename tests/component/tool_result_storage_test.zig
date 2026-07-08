//! L2 组件测试:大工具结果落盘(批1C,对齐 cc toolResultStorage)。

const std = @import("std");
const cc = @import("cc");

const storage = cc.tool_result_storage;

test "L2 落盘: 小结果不落盘(返 null)" {
    const a = std.testing.allocator;
    const r = try storage.maybePersist(a, "Grep", "small output", "/tmp/cc-trs-home");
    try std.testing.expect(r == null);
}

test "L2 落盘: 超阈值落盘 → preview+path,文件含全量" {
    const a = std.testing.allocator;
    _ = std.c.mkdir("/tmp/cc-trs-home", 0o755);
    // 造一个 > 50000 字符的结果
    const big = try a.alloc(u8, 60_000);
    defer a.free(big);
    @memset(big, 'X');
    @memcpy(big[0..6], "HEADER");

    const r = (try storage.maybePersist(a, "Grep", big, "/tmp/cc-trs-home")) orelse return error.ShouldPersist;
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"persisted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"original_bytes\":60000") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "HEADER") != null); // preview 含开头
    try std.testing.expect(std.mem.indexOf(u8, r, "/tmp/cc-trs-home/.metacodes/tool-results/") != null);

    // 落盘文件确实含全量(解析出 path,读回比对长度)
    const key = "\"path\":\"";
    const i = std.mem.indexOf(u8, r, key).? + key.len;
    const j = std.mem.indexOfScalarPos(u8, r, i, '"').?;
    const path = try a.dupeZ(u8, r[i..j]);
    defer a.free(path);
    const fd = std.c.open(path.ptr, std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var total: usize = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        total += @intCast(n);
    }
    try std.testing.expectEqual(@as(usize, 60_000), total);
    _ = std.c.unlink(path.ptr);
}

test "L2 落盘: home_dir 空 → 降级 inline 截断(不崩)" {
    const a = std.testing.allocator;
    const big = try a.alloc(u8, 60_000);
    defer a.free(big);
    @memset(big, 'Y');
    const r = (try storage.maybePersist(a, "Grep", big, "")) orelse return error.ShouldTruncate;
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"truncated\":true") != null);
    try std.testing.expect(r.len < 60_000); // 截断了
}

test "L2 落盘: Read 工具不落盘(自限,maxResultChars=max)" {
    try std.testing.expectEqual(std.math.maxInt(usize), storage.maxResultChars("Read"));
    try std.testing.expectEqual(storage.DEFAULT_MAX_RESULT_CHARS, storage.maxResultChars("Grep"));
}

test "L2 落盘: persistForced 无视阈值强制落盘小结果" {
    const a = std.testing.allocator;
    _ = std.c.mkdir("/tmp/cc-trs-home", 0o755);
    // 小结果(< 阈值),maybePersist 不落盘,但 persistForced 强制落盘
    try std.testing.expect((try storage.maybePersist(a, "Grep", "tiny", "/tmp/cc-trs-home")) == null);
    const r = (try storage.persistForced(a, "Grep", "tiny but forced", "/tmp/cc-trs-home")) orelse return error.ShouldPersist;
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"persisted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "tiny but forced") != null);
}
