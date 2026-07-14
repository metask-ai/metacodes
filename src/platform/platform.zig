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
