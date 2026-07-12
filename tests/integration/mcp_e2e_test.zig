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

fn elicitAcceptHandler(ctx: *anyopaque, _: []const u8, alloc: std.mem.Allocator) ?[]u8 {
    const called: *bool = @ptrCast(ctx);
    called.* = true;
    return alloc.dupe(u8, "{\"answer\":\"yes\"}") catch null;
}

test "MCP P0.3: elicitation 往返 — server 发 elicitation/create,client handler accept,tool 完成" {
    const a = std.testing.allocator;
    const mock_path: [*:0]const u8 = "zig-out/bin/mock_mcp_server";
    const argv = [_]?[*:0]const u8{ mock_path, null };
    var client = cc.mcp_client.McpClient.connect(a, argv[0..]) catch |err| {
        std.debug.print("connect failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer client.close();

    var handler_called = false;
    client.elicit = .{ .ctx = @ptrCast(&handler_called), .handleFn = elicitAcceptHandler };
    // callTool "elicit" → server 中途发 elicitation/create → client handler 应答 accept → server 回结果。
    const result = try client.callTool("elicit", "{}");
    defer a.free(result);
    try std.testing.expect(handler_called); // 回调确实被调
    try std.testing.expect(std.mem.indexOf(u8, result, "elicited:accept") != null); // server 收到 accept 并完成
}

test "MCP P0.3: 无 elicitation handler → 自动 decline,tool 仍完成(不 hang,不破协议)" {
    const a = std.testing.allocator;
    const mock_path: [*:0]const u8 = "zig-out/bin/mock_mcp_server";
    const argv = [_]?[*:0]const u8{ mock_path, null };
    var client = cc.mcp_client.McpClient.connect(a, argv[0..]) catch return;
    defer client.close();
    // 不设 handler → elicitation/create 被自动 decline。tool 仍拿到响应(不因未处理 server 请求而卡死)。
    const result = try client.callTool("elicit", "{}");
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "elicited:decline") != null);
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
