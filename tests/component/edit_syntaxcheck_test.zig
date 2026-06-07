//! L2 组件测试:Edit 改后语法检查(tree-sitter)。
//! 破坏语法的编辑 → 结果含 syntaxWarning;干净编辑 → 无 warning;不回滚(咨询性)。
//!
//! 走完整 Read→Edit dispatch 链(Edit 需 must-read-first)。

const std = @import("std");
const cc = @import("cc");

const tools = cc.tools;
const ToolContext = cc.tool_context.ToolContext;
const ReadState = cc.core_read_state.ReadState;

fn writeFile(path: []const u8, content: []const u8) !void {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, content.ptr, content.len);
}

fn ctxWithReadState(a: std.mem.Allocator, rs: *ReadState) ToolContext {
    var c = ToolContext.simple(a);
    c.read_state = rs;
    return c;
}

test "Edit 破坏语法 → syntaxWarning(不回滚)" {
    const a = std.testing.allocator;
    var rs = ReadState.init(a);
    defer rs.deinit();
    var c = ctxWithReadState(a, &rs);

    const path = "/tmp/cc-edit-syntax-break.zig";
    defer _ = std.c.unlink(path);
    try writeFile(path, "pub fn foo() void {\n    return;\n}\n");

    // 必须先 Read(满足 must-read-first + 记录 hash)
    const rout = try tools.dispatch(&c, "Read", "{\"file_path\":\"" ++ "/tmp/cc-edit-syntax-break.zig" ++ "\"}");
    a.free(rout);

    // 把闭合 } 删掉 → 语法破坏
    const eout = try tools.dispatch(&c, "Edit", "{\"file_path\":\"" ++ "/tmp/cc-edit-syntax-break.zig" ++ "\",\"old_string\":\"    return;\\n}\",\"new_string\":\"    return;\"}");
    defer a.free(eout);

    try std.testing.expect(std.mem.indexOf(u8, eout, "syntaxWarning") != null);
    try std.testing.expect(std.mem.indexOf(u8, eout, "\"success\":true") != null); // 仍成功(不回滚)
}

test "Edit 干净修改 → 无 syntaxWarning" {
    const a = std.testing.allocator;
    var rs = ReadState.init(a);
    defer rs.deinit();
    var c = ctxWithReadState(a, &rs);

    const path = "/tmp/cc-edit-syntax-clean.zig";
    defer _ = std.c.unlink(path);
    try writeFile(path, "pub fn foo() void {\n    return;\n}\n");

    const rout = try tools.dispatch(&c, "Read", "{\"file_path\":\"" ++ "/tmp/cc-edit-syntax-clean.zig" ++ "\"}");
    a.free(rout);

    // 改函数名,语法仍合法
    const eout = try tools.dispatch(&c, "Edit", "{\"file_path\":\"" ++ "/tmp/cc-edit-syntax-clean.zig" ++ "\",\"old_string\":\"foo\",\"new_string\":\"bar\"}");
    defer a.free(eout);

    try std.testing.expect(std.mem.indexOf(u8, eout, "syntaxWarning") == null);
    try std.testing.expect(std.mem.indexOf(u8, eout, "\"success\":true") != null);
}

test "Edit 非 tree-sitter 语言(.md)→ 无 syntaxWarning(不检查)" {
    const a = std.testing.allocator;
    var rs = ReadState.init(a);
    defer rs.deinit();
    var c = ctxWithReadState(a, &rs);

    const path = "/tmp/cc-edit-syntax.md";
    defer _ = std.c.unlink(path);
    try writeFile(path, "# Title\nsome body text\n");

    const rout = try tools.dispatch(&c, "Read", "{\"file_path\":\"" ++ "/tmp/cc-edit-syntax.md" ++ "\"}");
    a.free(rout);

    const eout = try tools.dispatch(&c, "Edit", "{\"file_path\":\"" ++ "/tmp/cc-edit-syntax.md" ++ "\",\"old_string\":\"body\",\"new_string\":\"BODY {{{ unbalanced\"}");
    defer a.free(eout);

    try std.testing.expect(std.mem.indexOf(u8, eout, "syntaxWarning") == null);
}

test "Edit 旧内容本已破损 → 不告警(没把它改得更坏)" {
    const a = std.testing.allocator;
    var rs = ReadState.init(a);
    defer rs.deinit();
    var c = ctxWithReadState(a, &rs);

    const path = "/tmp/cc-edit-already-broken.zig";
    defer _ = std.c.unlink(path);
    // 一开始就语法破损(缺闭合 + 散落括号)。
    try writeFile(path, "pub fn foo( void {{{\n    return\n");

    const rout = try tools.dispatch(&c, "Read", "{\"file_path\":\"" ++ "/tmp/cc-edit-already-broken.zig" ++ "\"}");
    a.free(rout);

    // 改其中一处,改完仍然破损 → syntaxRegressed 的核心非对称:旧已坏不算"这次改坏"。
    const eout = try tools.dispatch(&c, "Edit", "{\"file_path\":\"" ++ "/tmp/cc-edit-already-broken.zig" ++ "\",\"old_string\":\"return\",\"new_string\":\"return 1\"}");
    defer a.free(eout);

    try std.testing.expect(std.mem.indexOf(u8, eout, "syntaxWarning") == null);
    try std.testing.expect(std.mem.indexOf(u8, eout, "\"success\":true") != null);
}
