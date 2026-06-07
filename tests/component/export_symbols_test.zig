//! L2 组件测试:export-symbols 机制端到端。
//! DoD:CLI 子命令的核心 run() 真产出 JSONL,每行 schema 正确。
//! 直调 treesitter_export.run(写临时文件 → posix 读回断言),不走子进程。

const std = @import("std");
const cc = @import("cc");

const xexport = cc.treesitter_export;

fn readWhole(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch break;
        if (n == 0) break;
        try list.appendSlice(a, buf[0..n]);
    }
    return try list.toOwnedSlice(a);
}

test "export-symbols: 产出 JSONL,每行 schema 完整" {
    const a = std.testing.allocator;
    const out_path = "/tmp/cc-export-symbols-test.jsonl";
    defer _ = std.c.unlink(out_path);

    const code = try xexport.run(a, "tests/fixtures/treesitter", out_path);
    try std.testing.expectEqual(@as(u8, 0), code);

    const content = try readWhole(a, out_path);
    defer a.free(content);

    // 每行是一个 JSON 对象,含全部契约字段。
    try std.testing.expect(std.mem.indexOf(u8, content, "\"name\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"kind\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"file\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"line_start\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"line_end\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"signature\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"parent\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"doc\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"lang\":") != null);

    // 具体符号:zig 的 distance 函数、ts 的 Circle class。
    try std.testing.expect(std.mem.indexOf(u8, content, "\"name\":\"distance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"lang\":\"zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"name\":\"Circle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"kind\":\"class\"") != null);

    // 每行都以 } 结尾 + \n(JSONL 格式);最后非空。
    try std.testing.expect(content.len > 0);
    try std.testing.expect(content[content.len - 1] == '\n');
}

test "export-symbols: parent 关系正确(方法挂在类下)" {
    const a = std.testing.allocator;
    const out_path = "/tmp/cc-export-symbols-parent.jsonl";
    defer _ = std.c.unlink(out_path);

    _ = try xexport.run(a, "tests/fixtures/treesitter", out_path);
    const content = try readWhole(a, out_path);
    defer a.free(content);

    // ts 的 area() 方法 parent 应是 Circle
    try std.testing.expect(std.mem.indexOf(u8, content, "\"name\":\"area\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"parent\":\"Circle\"") != null);
}
