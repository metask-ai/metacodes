//! LSP 子系统根(Y2 Step2:被动诊断,对标 hermes)。
//!
//! v1 passive-only + documentSymbol:push diagnostics(publishDiagnostics)+ didOpen/didChange/didSave
//! + textDocument/documentSymbol(替 tree-sitter 供 CodeMap/FindSymbol/Read-outline);不做 pull
//! (textDocument/diagnostic)、不做 hover/definition。opt-in `--lsp` + git
//! workspace gate + 按需 spawn + broken-set + idle-reap + graceful degradation。
//!
//! 模块:transport(Content-Length 帧+spawn)/protocol(JSON-RPC envelope)/client(单 server
//! reader 线程+req/resp 关联+wait diagnostics)/service(spawn cache+broken-set+delta baseline)/
//! workspace(git 门)/servers(ServerDef 注册表)/reporter(格式化+XSS)/range_shift(行移 delta)。

pub const transport = @import("transport.zig");
pub const protocol = @import("protocol.zig");
pub const reporter = @import("reporter.zig");
pub const workspace = @import("workspace.zig");
pub const servers = @import("servers.zig");
pub const client = @import("client.zig");
pub const service = @import("service.zig");
pub const symbols = @import("symbols.zig");

test {
    _ = transport;
    _ = protocol;
    _ = reporter;
    _ = workspace;
    _ = servers;
    _ = client;
    _ = service;
    _ = symbols;
}
