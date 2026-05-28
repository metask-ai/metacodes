//! MCP 端到端测试：spawn mock_mcp_server → initialize → tools/list → tools/call。

const std = @import("std");
const cc = @import("cc");

test "MCP: full cycle initialize + listTools + callTool echo" {
    const a = std.testing.allocator;
    const mock_path: [*:0]const u8 = "zig-out/bin/mock_mcp_server";
    const argv = [_]?[*:0]const u8{ mock_path, null };

    // connect 内做了 initialize
    var client = cc.mcp_client.McpClient.connect(a, argv[0..]) catch |err| {
        std.debug.print("McpClient.connect failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer client.close();

    // listTools：期望包含 "echo"
    const tools_json = try client.listTools();
    defer a.free(tools_json);
    try std.testing.expect(std.mem.indexOf(u8, tools_json, "echo") != null);

    // callTool echo
    const result = try client.callTool("echo", "{\"message\":\"hello mcp\"}");
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "hello mcp") != null);
}

test "MCP: dispatch via DynRegistry routes mock__echo to MCP server" {
    const a = std.testing.allocator;
    const mock_path: [*:0]const u8 = "zig-out/bin/mock_mcp_server";
    const argv = [_]?[*:0]const u8{ mock_path, null };

    var client = try cc.mcp_client.McpClient.connect(a, argv[0..]);
    defer client.close();

    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    var session = cc.mcp_registry_bridge.McpSession.init(a, &client);
    defer session.deinit();
    try session.registerTools(&dyn, "mock");

    // 现在 dispatch 应当能找到 mock__echo 并调用,得到包含 "hi via dispatch" 的结果
    var ctx = cc.tools.ToolContext.simple(a);
    ctx.dyn_registry = &dyn;
    const out = try cc.tools.dispatch(&ctx, "mock__echo", "{\"message\":\"hi via dispatch\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "hi via dispatch") != null);
}

test "MCP: registerResourceTools adds list_resources + read_resource" {
    const a = std.testing.allocator;
    const mock_path: [*:0]const u8 = "zig-out/bin/mock_mcp_server";
    const argv = [_]?[*:0]const u8{ mock_path, null };

    var client = try cc.mcp_client.McpClient.connect(a, argv[0..]);
    defer client.close();

    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    var session = cc.mcp_registry_bridge.McpSession.init(a, &client);
    defer session.deinit();
    try session.registerResourceTools(&dyn, "mock");

    try std.testing.expect(dyn.find("mock__list_resources") != null);
    try std.testing.expect(dyn.find("mock__read_resource") != null);
}
