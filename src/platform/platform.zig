//! platform —— 可移植系统抽象层聚合根（跨平台移植 roadmap，tinykg node 8861）。
//!
//! 作为命名模块 `"platform"` 暴露给各构建模块（含 test:lsp 隔离模块——lsp/ 子系统根在
//! src/lsp/，无法相对 import 上层 ../platform/，故必须走命名模块）。非 lsp 代码仍可直接
//! 相对 `@import("../platform/<x>.zig")`（同一文件，Zig 按 realpath 去重，类型一致）。

pub const sync = @import("sync.zig");
pub const process = @import("process.zig");
pub const fs = @import("fs.zig");
pub const signal = @import("signal.zig");
pub const rng = @import("rng.zig");
pub const paths = @import("paths.zig");
pub const terminal = @import("terminal.zig");
pub const win32_input = @import("win32_input.zig");
pub const net = @import("net.zig");
pub const dir = @import("dir.zig");
pub const exe_lookup = @import("exe_lookup.zig");
pub const timezone = @import("timezone.zig");
pub const process_scan = @import("process_scan.zig");
/// Thread creation with a stated stack class (#503); see the file header.
pub const thread = @import("thread.zig");
/// 测试夹具(symlink-or-skip / junction / 目录枚举断言 / 按 tick 早醒的虚拟时钟)。只在 test 块里用;见文件头。
pub const test_support = @import("test_support.zig");

// 测试发现:Zig 只收集**被引用到**的文件里的 test 块。此前本文件只有一串 `pub const x =
// @import(...)`,没有引用它们的 test 块 —— `zig build test:platform` 因此长期跑 0 个测试,
// 而 `windows:gate` 正是挂在这个 step 上,于是整个 Windows 平台闸门是空跑绿的。
// refAllDecls 引用上面每个 `pub const`,所以上面那串就是唯一的模块清单:CI 的
// "Native platform modules" 也只编本文件。它曾自带一份逐模块清单,漏了 terminal 与
// timezone,两者在 Linux/macOS 上从没进过 CI。
test {
    @import("std").testing.refAllDecls(@This());
}
