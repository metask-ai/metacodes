//! LSP 子系统根(Y2 Step2:被动诊断,对标 hermes)。
//!
//! v1 passive-only + documentSymbol:push diagnostics(publishDiagnostics)+ didOpen/didChange/didSave
//! + textDocument/documentSymbol(替 tree-sitter 供 CodeMap/FindSymbol/Read-outline);不做 pull
//! (textDocument/diagnostic)、不做 hover/definition。**默认开**(`--no-lsp` 关)+ git
//! workspace gate + 二进制可用性门 + 按需 spawn + broken-set + idle-reap + graceful degradation。
//!
//! 模块:transport(Content-Length 帧+spawn)/protocol(JSON-RPC envelope)/client(单 server
//! reader 线程+req/resp 关联+wait diagnostics)/service(spawn cache+broken-set+delta baseline)/
//! workspace(git 门)/servers(ServerDef 注册表 + 二进制可用性谓词)/capability(符号能力
//! 三态词汇表)/reporter(格式化+XSS)/range_shift(行移 delta)。
//!
//! ## Windows 支持现状(**尚未支持,逐条登记,勿凭"PATH 修好了"就宣称可用**)
//!
//! | 环节 | 状态 |
//! |------|------|
//! | PATH 解析 server 二进制(`servers.which`) | ✅ 已平台正确化,下沉到 `platform.exe_lookup`(`;` 切 / `\` 拼 / `PATHEXT` 试探) |
//! | 子进程 spawn / pipe / poll / terminate(`transport` → `platform.process`) | ✅ 已有真 Windows 实现(CreatePipe + CreateProcessW + PeekNamedPipe + TerminateProcess) |
//! | `workspace.isInsideWorkspace` 的边界判定 | ❌ 只认 `'/'` 作分隔符,`C:\proj` + `\src\a.zig` 判定为**不在 workspace 内** → 整个 LSP 门被关掉 |
//! | `client.pathToUri` 产的 `file://` URI | ❌ 出 `file://C:\proj\a.zig`,LSP 规范要的是 `file:///c%3A/proj/a.zig`(盘符 + 百分号编码 + 正斜杠) |
//! | npm 装出的 `.cmd` / `.bat` server 垫片 | ❌ `CreateProcess` 不能直接执行批处理,必须 `cmd.exe /c` 转发(`typescript-language-server` 在 Windows 上正是这个形态) |
//!
//! 后两条不是"没做完",是**两件独立的事**:URI 要连同 `uriToPath` 一起改并做往返测试;
//! `.cmd` 垫片要处理 `cmd.exe /c` 与 `CreateProcess` **不同的**引号规则(注入面),
//! 都需要在真 Windows 上验证,不宜与 PATH 修复混在一起。
//! 上表任一行由 ❌ 转 ✅ 时,**同时更新这里**——这张表是唯一的 Windows 就绪声明。

pub const transport = @import("transport.zig");
pub const protocol = @import("protocol.zig");
pub const reporter = @import("reporter.zig");
pub const workspace = @import("workspace.zig");
pub const servers = @import("servers.zig");
pub const capability = @import("capability.zig");
pub const client = @import("client.zig");
pub const service = @import("service.zig");
pub const symbols = @import("symbols.zig");

test {
    _ = transport;
    _ = protocol;
    _ = reporter;
    _ = workspace;
    _ = servers;
    _ = capability;
    _ = client;
    _ = service;
    _ = symbols;
}
