//! L2 组件测试:schema 层 required 字段校验(对齐 cc zod safeParse 层)。
//!
//! dispatch 前统一校验 input 含所有 required 字段;缺则 error.MissingRequiredField
//! (→ invalid_args 给模型现场)。这是工具自身 MissingX 之外的统一前置层。

const std = @import("std");
const cc = @import("cc");

const tools = cc.tools;

test "L2 schema: Write 缺 content → MissingRequiredField" {
    // Write required = file_path + content
    try std.testing.expectError(error.MissingRequiredField, tools.validateRequired("Write", "{\"file_path\":\"/x\"}"));
}

test "L2 schema: Write 齐全 → 通过" {
    try tools.validateRequired("Write", "{\"file_path\":\"/x\",\"content\":\"hi\"}");
}

test "L2 schema: Edit 缺 old_string → 拦" {
    try std.testing.expectError(error.MissingRequiredField, tools.validateRequired("Edit", "{\"file_path\":\"/x\",\"new_string\":\"y\"}"));
    // 齐全通过
    try tools.validateRequired("Edit", "{\"file_path\":\"/x\",\"old_string\":\"a\",\"new_string\":\"b\"}");
}

test "L2 schema: Grep 缺 pattern → 拦" {
    try std.testing.expectError(error.MissingRequiredField, tools.validateRequired("Grep", "{\"path\":\".\"}"));
    try tools.validateRequired("Grep", "{\"pattern\":\"foo\"}");
}

test "L2 schema: Task 只需 prompt(subagent_type/description 有默认不必需)" {
    // 只给 prompt → 通过(subagent_type 缺省 general-purpose,不应被拦)
    try tools.validateRequired("Task", "{\"prompt\":\"do it\"}");
    // 缺 prompt → 拦
    try std.testing.expectError(error.MissingRequiredField, tools.validateRequired("Task", "{\"subagent_type\":\"Explore\"}"));
}

test "L2 schema: 未知工具 → 不拦(交给 dyn/UnknownTool)" {
    try tools.validateRequired("__nope__", "{}");
}

test "L2 schema: MissingRequiredField 归 invalid_args" {
    const a = std.testing.allocator;
    const j = try cc.tool_error.errorToJson("MissingRequiredField", "{s} failed", .{"MissingRequiredField"}, a);
    defer a.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "invalid_args") != null);
}
