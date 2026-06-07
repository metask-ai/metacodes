//! tree-sitter L1 单测聚合入口(test:ts 步骤的 root)。
//! 隔离于主 test 套件,绕开 integration 测试的 TTY 挂起;接 addTreeSitter 链 C。
//! 新增 treesitter 子模块时在此 _ = @import 进来。
test {
    _ = &@import("ts.zig");
    _ = &@import("symbols.zig");
    _ = &@import("highlight.zig");
}
