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
pub const net = @import("net.zig");
pub const dir = @import("dir.zig");
pub const exe_lookup = @import("exe_lookup.zig");

// 测试发现:Zig 只收集**被引用到**的文件里的 test 块。此前本文件只有一串 `pub const x =
// @import(...)`,没有引用它们的 test 块 —— `zig build test:platform` 因此长期跑 0 个测试,
// 而 `windows:gate` 正是挂在这个 step 上,于是整个 Windows 平台闸门是空跑绿的。
// 加语句块把每个子模块钉进测试图(与 `src/lsp/lsp.zig` 同款)。**新增子模块必须同时补一行**。
test {
    _ = sync;
    _ = process;
    _ = fs;
    _ = signal;
    _ = rng;
    _ = paths;
    _ = terminal;
    _ = net;
    _ = dir;
    _ = exe_lookup;
}
