//! L2 组件测试:Stage 3 — 预置应答通道端到端贯穿。
//!
//! 设计目标(doc/E2E_FRAMEWORK_DESIGN.md Stage 3):
//!   非 tty 下权限 .ask 从 answer_queue 按序弹应答,而非读 fd 0(被 REPL 行流独占)。
//!
//! 这里测真实链路 `answer_queue.load → permission.promptUser → prompt.ask →
//!   askText → answer_queue.pop`,无 socket(权限 prompt 是本地决策)。

const std = @import("std");
const cc = @import("cc");

// 贯通:load 队列 → promptUser 按 pop 的 y/n 返 true/false。
test "L2 Stage3: promptUser 从 answer_queue 按序弹 y/n" {
    const a = std.testing.allocator;
    var ctx = cc.permission.PermissionContext{ .allocator = a };

    cc.answer_queue.load("y\nn\na\n");

    // 第一问:y → 允许
    try std.testing.expect(try cc.permission.promptUser(&ctx, "Write", "{\"path\":\"x\"}"));
    // 第二问:n → 拒绝
    try std.testing.expect(!(try cc.permission.promptUser(&ctx, "Write", "{\"path\":\"y\"}")));
    // 第三问:a(always) → 允许
    try std.testing.expect(try cc.permission.promptUser(&ctx, "Bash", "{\"command\":\"ls\"}"));

    cc.answer_queue.resetForTest();
}

// 队列耗尽 → 安全默认 deny(不读 fd 0,不死等)。
test "L2 Stage3: 队列耗尽 → 默认 deny" {
    const a = std.testing.allocator;
    var ctx = cc.permission.PermissionContext{ .allocator = a };
    cc.answer_queue.load("y\n");
    try std.testing.expect(try cc.permission.promptUser(&ctx, "Write", "{}")); // 弹 y
    // 队列空 → isActive false → 走原非 tty 文字路径,fd 0 在 test 下无输入 → deny
    try std.testing.expect(!(try cc.permission.promptUser(&ctx, "Write", "{}")));
    cc.answer_queue.resetForTest();
}

// 单元 sanity:load/pop 顺序 + 耗尽(对齐 answer_queue.zig 内单测,跨模块复核)。
test "L2 Stage3: answer_queue pop 顺序" {
    cc.answer_queue.load("first\nsecond\nThe blue one\n");
    try std.testing.expectEqualStrings("first", cc.answer_queue.pop().?);
    try std.testing.expectEqualStrings("second", cc.answer_queue.pop().?);
    try std.testing.expectEqualStrings("The blue one", cc.answer_queue.pop().?);
    try std.testing.expect(cc.answer_queue.pop() == null);
    cc.answer_queue.resetForTest();
}
