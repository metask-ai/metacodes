//! McpSessionEntry:一个已连接的 MCP server(McpClient + McpSession 一一对应)。
//!
//! 从 app.zig 移出到中立 core 位置:agent_loop.Options / ToolContext / mcp_resources 工具
//! 都引用它(ListMcpResourcesTool/ReadMcpResourceTool 用),原先经 `@import("../app.zig")`
//! 造成 core→app 泄漏。这里只依赖 mcp/(库内),无 app 依赖。
const McpClient = @import("../mcp/client.zig").McpClient;
const McpSession = @import("../mcp/registry_bridge.zig").McpSession;

pub const McpSessionEntry = struct {
    name: []u8,
    client: *McpClient,
    session: McpSession,
};
