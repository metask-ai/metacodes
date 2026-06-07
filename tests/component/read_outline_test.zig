//! L2 组件测试:Read 工具 outline 模式(走 dispatch 整链)。
//! DoD:outline schema 字段真生效(返回符号大纲而非文件内容)。
//! 同时验证向后兼容:不传 outline → 正常读取内容(带行号)。

const std = @import("std");
const cc = @import("cc");

const tools = cc.tools;
const ToolContext = cc.tool_context.ToolContext;

fn ctx(a: std.mem.Allocator) ToolContext {
    return ToolContext.simple(a);
}

const ZIG_FIX = "tests/fixtures/treesitter/sample.zig";

test "Read outline=true → 返回符号大纲(非文件内容)" {
    const a = std.testing.allocator;
    var c = ctx(a);
    const out = try tools.dispatch(&c, "Read", "{\"file_path\":\"" ++ ZIG_FIX ++ "\",\"outline\":true}");
    defer a.free(out);
    // 大纲含符号名 + kind
    try std.testing.expect(std.mem.indexOf(u8, out, "struct Point") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "distance") != null);
    // 不应是带行号的原始内容(原始内容会有 "const std = @import" 这种行体)
    try std.testing.expect(std.mem.indexOf(u8, out, "@floatFromInt") == null);
}

test "Read 默认(无 outline)→ 正常带行号内容(向后兼容)" {
    const a = std.testing.allocator;
    var c = ctx(a);
    const out = try tools.dispatch(&c, "Read", "{\"file_path\":\"" ++ ZIG_FIX ++ "\"}");
    defer a.free(out);
    // 正常内容含实现行体
    try std.testing.expect(std.mem.indexOf(u8, out, "@floatFromInt") != null);
    // 带行号前缀(cat -n 风格,行号 + tab)
    try std.testing.expect(std.mem.indexOf(u8, out, "\t") != null);
}

test "Read outline=true 对不支持的扩展名 → 回退正常读取" {
    const a = std.testing.allocator;
    var c = ctx(a);
    // .md 不被 tree-sitter 支持 → outline 应被忽略,正常读内容(向后兼容)。
    const out = try tools.dispatch(&c, "Read", "{\"file_path\":\"tests/fixtures/treesitter/sample.md\",\"outline\":true}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "some text here") != null);
}
