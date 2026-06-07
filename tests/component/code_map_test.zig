//! L2 组件测试:CodeMap 工具端到端(走 dispatch 整链)。
//! DoD:验证 path / lang schema 字段真生效(输出含期望符号 + 行号);
//! 缺 path → MissingRequiredField。
//!
//! cwd 约定:zig build test 在 repo 根跑,fixtures 在 tests/fixtures/treesitter/。

const std = @import("std");
const cc = @import("cc");

const tools = cc.tools;
const ToolContext = cc.tool_context.ToolContext;

fn ctx(a: std.mem.Allocator) ToolContext {
    return ToolContext.simple(a);
}

const ZIG_FIX = "tests/fixtures/treesitter/sample.zig";

test "CodeMap: 缺 path → MissingRequiredField" {
    const a = std.testing.allocator;
    var c = ctx(a);
    try std.testing.expectError(error.MissingRequiredField, tools.dispatch(&c, "CodeMap", "{}"));
}

test "CodeMap: 单 zig 文件 → 含函数/struct/enum + 行号" {
    const a = std.testing.allocator;
    var c = ctx(a);
    const args = "{\"path\":\"" ++ ZIG_FIX ++ "\"}";
    const out = try tools.dispatch(&c, "CodeMap", args);
    defer a.free(out);

    // 文件名作为标题出现
    try std.testing.expect(std.mem.indexOf(u8, out, "sample.zig") != null);
    // 顶层符号
    try std.testing.expect(std.mem.indexOf(u8, out, "Point") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Color") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "distance") != null);
    // kind 标注
    try std.testing.expect(std.mem.indexOf(u8, out, "struct Point") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "enum Color") != null);
    // 方法 add 缩进在 Point 下(parent 关系)→ 出现且带更深缩进
    try std.testing.expect(std.mem.indexOf(u8, out, "add") != null);
    // 行号区间格式 (start-end)
    try std.testing.expect(std.mem.indexOf(u8, out, "(") != null and std.mem.indexOf(u8, out, "-") != null);
}

test "CodeMap: lang 覆盖真改行为(.inc 含 zig 代码,无 lang 不识别)" {
    const a = std.testing.allocator;
    var c = ctx(a);
    const INC = "tests/fixtures/treesitter/zigcode.inc";
    // 无 lang:.inc 扩展名不被识别 → unsupported
    const noforce = try tools.dispatch(&c, "CodeMap", "{\"path\":\"" ++ INC ++ "\"}");
    defer a.free(noforce);
    try std.testing.expect(std.mem.indexOf(u8, noforce, "unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, noforce, "forced_lang_marker") == null);

    // lang=zig 强制 → 抽出符号
    const forced = try tools.dispatch(&c, "CodeMap", "{\"path\":\"" ++ INC ++ "\",\"lang\":\"zig\"}");
    defer a.free(forced);
    try std.testing.expect(std.mem.indexOf(u8, forced, "forced_lang_marker") != null);
}

test "CodeMap: 非法 lang 值 → 报错(不静默忽略 typo)" {
    const a = std.testing.allocator;
    var c = ctx(a);
    try std.testing.expectError(
        error.UnsupportedLanguage,
        tools.dispatch(&c, "CodeMap", "{\"path\":\"" ++ ZIG_FIX ++ "\",\"lang\":\"javascript\"}"),
    );
}

test "CodeMap: tsx 文件(JSX)→ class/interface/method" {
    const a = std.testing.allocator;
    var c = ctx(a);
    const out = try tools.dispatch(&c, "CodeMap", "{\"path\":\"tests/fixtures/treesitter/sample.tsx\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "class Panel") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "interface Props") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "App") != null);
}

test "CodeMap: glob 零命中 → 友好提示不崩" {
    const a = std.testing.allocator;
    var c = ctx(a);
    const out = try tools.dispatch(&c, "CodeMap", "{\"path\":\"tests/fixtures/treesitter/*.nonexistent_ext\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "no files matched") != null);
}

test "CodeMap: glob 批量(*.zig fixture)→ 多文件" {
    const a = std.testing.allocator;
    var c = ctx(a);
    const args = "{\"path\":\"tests/fixtures/treesitter/*.zig\"}";
    const out = try tools.dispatch(&c, "CodeMap", args);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "sample.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Point") != null);
}

test "CodeMap: typescript 文件 → class/interface/method" {
    const a = std.testing.allocator;
    var c = ctx(a);
    const out = try tools.dispatch(&c, "CodeMap", "{\"path\":\"tests/fixtures/treesitter/sample.ts\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "class Circle") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "interface Shape") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "midpoint") != null);
}

test "CodeMap: bash 文件 → function 符号" {
    const a = std.testing.allocator;
    var c = ctx(a);
    const out = try tools.dispatch(&c, "CodeMap", "{\"path\":\"tests/fixtures/treesitter/sample.sh\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "farewell") != null);
}
