//! MCP 端到端测试：spawn mock_mcp_server → initialize → tools/list → tools/call。

const std = @import("std");
const cc = @import("cc");
const sync = @import("platform").sync;

fn dispatchOk(ctx: *const cc.tools.ToolContext, name: []const u8, args: []const u8) ![]u8 {
    var outcome = try cc.tools.dispatch(ctx, name, args);
    return switch (outcome) {
        .ok => |bytes| bytes,
        else => {
            outcome.deinit(ctx.allocator);
            return error.UnexpectedDispatchOutcome;
        },
    };
}

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

const ConcurrentStart = struct {
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    ready: usize = 0,
    go: bool = false,

    fn wait(self: *ConcurrentStart) void {
        self.mutex.lock();
        self.ready += 1;
        self.cond.broadcast();
        while (!self.go) self.cond.wait(&self.mutex);
        self.mutex.unlock();
    }
};

const ConcurrentCall = struct {
    client: *cc.mcp_client.McpClient,
    start: *ConcurrentStart,
    message: []const u8,
    output: ?[]u8 = null,

    fn run(self: *ConcurrentCall) void {
        self.start.wait();
        const args = std.fmt.allocPrint(std.heap.c_allocator, "{{\"message\":\"{s}\"}}", .{self.message}) catch return;
        defer std.heap.c_allocator.free(args);
        self.output = self.client.callTool("slow_echo", args) catch null;
    }
};

test "MCP: parallel tool calls serialize one stdio JSON-RPC stream" {
    const a = std.heap.c_allocator;
    const mock_path: [*:0]const u8 = "zig-out/bin/mock_mcp_server";
    const argv = [_]?[*:0]const u8{ mock_path, null };
    var client = try cc.mcp_client.McpClient.connect(a, argv[0..]);
    defer client.close();

    var start = ConcurrentStart{};
    var first = ConcurrentCall{ .client = &client, .start = &start, .message = "first" };
    var second = ConcurrentCall{ .client = &client, .start = &start, .message = "second" };
    const t1 = try std.Thread.spawn(.{}, ConcurrentCall.run, .{&first});
    const t2 = try std.Thread.spawn(.{}, ConcurrentCall.run, .{&second});

    start.mutex.lock();
    while (start.ready != 2) start.cond.wait(&start.mutex);
    start.go = true;
    start.cond.broadcast();
    start.mutex.unlock();

    t1.join();
    t2.join();
    const first_out = first.output orelse return error.FirstConcurrentMcpCallFailed;
    defer a.free(first_out);
    const second_out = second.output orelse return error.SecondConcurrentMcpCallFailed;
    defer a.free(second_out);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_out, "second") != null);
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
    const out = try dispatchOk(&ctx, "mock__echo", "{\"message\":\"hi via dispatch\"}");
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
