//! L2 组件测试:FindSymbol 工具端到端(走 dispatch 整链)。
//! DoD:name / kind / path schema 字段真生效。
//! FindSymbol 是 deferred,但 dispatch 直接可跑(deferral 只影响 prompt 曝光)。

const std = @import("std");
const cc = @import("cc");

const tools = cc.tools;
const ToolContext = cc.tool_context.ToolContext;

fn ctx(a: std.mem.Allocator) ToolContext {
    return ToolContext.simple(a);
}

const FIX_DIR = "tests/fixtures/treesitter";

test "FindSymbol: 缺 name → MissingRequiredField" {
    const a = std.testing.allocator;
    var c = ctx(a);
    try std.testing.expectError(error.MissingRequiredField, tools.dispatch(&c, "FindSymbol", "{}"));
}

test "FindSymbol: 找 distance(zig 函数定义)→ file:line + signature" {
    const a = std.testing.allocator;
    var c = ctx(a);
    const out = try tools.dispatch(&c, "FindSymbol", "{\"name\":\"distance\",\"path\":\"" ++ FIX_DIR ++ "\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"distance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sample.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":") != null);
}

test "FindSymbol: kind 过滤收窄(struct Point vs 同名其它)" {
    const a = std.testing.allocator;
    var c = ctx(a);
    // Point 在 zig fixture 是 struct;kind=struct 应命中
    const out = try tools.dispatch(&c, "FindSymbol", "{\"name\":\"Point\",\"kind\":\"struct\",\"path\":\"" ++ FIX_DIR ++ "\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Point\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"struct\"") != null);

    // kind=function 对 Point 应不命中(Point 不是函数)→ 空数组
    const out2 = try tools.dispatch(&c, "FindSymbol", "{\"name\":\"Point\",\"kind\":\"function\",\"path\":\"" ++ FIX_DIR ++ "\"}");
    defer a.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "\"kind\":\"struct\"") == null);
}

test "FindSymbol: 不存在的符号 → 空数组" {
    const a = std.testing.allocator;
    var c = ctx(a);
    const out = try tools.dispatch(&c, "FindSymbol", "{\"name\":\"__no_such_symbol_xyz__\",\"path\":\"" ++ FIX_DIR ++ "\"}");
    defer a.free(out);
    try std.testing.expectEqualStrings("[]", out);
}

test "FindSymbol: path 作用域真排除(Point 在 .zig 和 .c 都有,限定 .c 不返 .zig)" {
    const a = std.testing.allocator;
    var c = ctx(a);
    // Point 同时定义在 sample.zig 和 sample.c。把 path 限到只含 .c 的 glob。
    const out = try tools.dispatch(&c, "FindSymbol", "{\"name\":\"Point\",\"path\":\"tests/fixtures/treesitter/sample.c\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "sample.c") != null);
    // 关键:作用域外的 sample.zig 的 Point 必须被排除。
    try std.testing.expect(std.mem.indexOf(u8, out, "sample.zig") == null);
}

test "FindSymbol: 只有用法没有定义 → 空数组(区别于 Grep)" {
    const a = std.testing.allocator;
    var c = ctx(a);
    // sqrt 在 sample.c 里被*调用*(math.h 的 sqrt),但 fixture 里从无定义。
    const out = try tools.dispatch(&c, "FindSymbol", "{\"name\":\"sqrt\",\"path\":\"" ++ FIX_DIR ++ "\"}");
    defer a.free(out);
    try std.testing.expectEqualStrings("[]", out);
}

test "FindSymbol: tsx 定义(Panel class)可被找到" {
    const a = std.testing.allocator;
    var c = ctx(a);
    const out = try tools.dispatch(&c, "FindSymbol", "{\"name\":\"Panel\",\"path\":\"" ++ FIX_DIR ++ "\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "sample.tsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"class\"") != null);
}
