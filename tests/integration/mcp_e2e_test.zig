//! MCP 端到端测试：spawn mock_mcp_server → initialize → tools/list → tools/call。

const std = @import("std");
const cc = @import("cc");
const pfs = @import("platform").fs;
const sync = @import("platform").sync;

fn dispatchOk(ctx: *const cc.tools.ToolContext, name: []const u8, args: []const u8) ![]u8 {
    var outcome = try cc.tools.dispatch(ctx, name, args);
    return switch (outcome) {
        .ok => |*body| (try body.takeModelBytes(ctx.allocator)).bytes,
        else => {
            outcome.deinit(ctx.allocator);
            return error.UnexpectedDispatchOutcome;
        },
    };
}

fn expectedSizedResourceResult(allocator: std.mem.Allocator, payload_bytes: usize) ![]u8 {
    const payload = try allocator.alloc(u8, payload_bytes);
    defer allocator.free(payload);
    @memset(payload, 's');
    return std.fmt.allocPrint(
        allocator,
        "{{\"contents\":[{{\"uri\":\"mock://sized/{d}\",\"mimeType\":\"text/plain\",\"text\":\"{s}\"}}]}}",
        .{ payload_bytes, payload },
    );
}

fn fillSessionArtifactQuota(allocator: std.mem.Allocator, root: []const u8) !void {
    const seed = try cc.tool_result_artifact.persist(allocator, root, "seed");
    _ = seed;
    const filler = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/tool-results/sha256/quota-fixture.blob",
        .{root},
        0,
    );
    defer allocator.free(filler);
    const fd = pfs.open(
        filler.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true },
        0o600,
    );
    if (fd < 0) return error.QuotaFixtureOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.setSize(fd, cc.tool_result_artifact.MAX_SESSION_BYTES);
}

fn expectSizedResourceBody(
    expected_result_bytes: usize,
    expect_artifact: bool,
    fill_quota: bool,
) !void {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    if (fill_quota) try fillSessionArtifactQuota(allocator, root);
    const mock_path: [*:0]const u8 = "zig-out/bin/mock_mcp_server";
    const argv = [_]?[*:0]const u8{ mock_path, null };
    var client = try cc.mcp_client.McpClient.connect(allocator, argv[0..]);
    defer client.close();

    const server_name = try allocator.dupe(u8, "mock");
    defer allocator.free(server_name);
    var entries = [_]cc.mcp_session.McpSessionEntry{.{
        .name = server_name,
        .client = &client,
        .session = cc.mcp_registry_bridge.McpSession.init(allocator, &client),
    }};
    defer entries[0].session.deinit();
    var sessions: []cc.mcp_session.McpSessionEntry = entries[0..];
    const budget = cc.result_budget.Budget.fromModel(200_000);
    try std.testing.expectEqual(@as(usize, 25_000), budget.per_result_bytes);
    var ctx = cc.tools.ToolContext.simple(allocator);
    ctx.artifact_root = root;
    ctx.result_budget = budget;
    ctx.mcp_sessions = &sessions;

    const overhead_fixture = try expectedSizedResourceResult(allocator, expected_result_bytes);
    defer allocator.free(overhead_fixture);
    const envelope_overhead = overhead_fixture.len - expected_result_bytes;
    const payload_bytes = expected_result_bytes - envelope_overhead;
    const args = try std.fmt.allocPrint(
        allocator,
        "{{\"uri\":\"mock://sized/{d}\",\"server\":\"mock\"}}",
        .{payload_bytes},
    );
    defer allocator.free(args);
    const expected = try expectedSizedResourceResult(allocator, payload_bytes);
    defer allocator.free(expected);
    try std.testing.expectEqual(expected_result_bytes, expected.len);

    var read = try cc.tools.dispatch(&ctx, "ReadMcpResourceTool", args);
    defer read.deinit(allocator);
    const body = switch (read) {
        .ok => |*value| value,
        else => return error.UnexpectedResourceReadOutcome,
    };
    if (expect_artifact) {
        try std.testing.expect(body.* == .artifact);
        try std.testing.expectEqual(@as(u64, expected.len), body.artifact.stored.bytes);
        try std.testing.expectEqualStrings(
            expected[0..body.artifact.preview.head_len],
            body.artifact.preview.headSlice(),
        );
    } else {
        try std.testing.expect(body.* == .@"inline");
        try std.testing.expectEqualStrings(expected, body.@"inline".bytes);
    }
}

test "MCP budget: resources/read publishes result above caller per-result budget" {
    try expectSizedResourceBody(30_000, true, false);
}

test "MCP budget: resources/read inlines result at caller per-result budget" {
    try expectSizedResourceBody(25_000, false, false);
}

test "MCP budget: resources/read retains bounded result inline when publication fails" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try expectSizedResourceBody(30_000, false, true);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
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
    ctx.artifact_root = root;
    ctx.dyn_registry = &dyn;
    const out = try dispatchOk(&ctx, "mock__echo", "{\"message\":\"hi via dispatch\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "hi via dispatch") != null);
}

test "MCP: CLI stdio captures 17MiB from byte zero and dispatch preserves typed artifact" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const mock_path: [*:0]const u8 = "zig-out/bin/mock_mcp_server";
    const argv = [_]?[*:0]const u8{ mock_path, null };
    var client = try cc.mcp_client.McpClient.connect(a, argv[0..]);
    defer client.close();
    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    var session = cc.mcp_registry_bridge.McpSession.init(a, &client);
    defer session.deinit();
    try session.registerTools(&dyn, "mock");
    const entry = dyn.find("mock__large") orelse return error.MissingLargeMcpTool;
    try std.testing.expect(entry.executor == .result_body);
    var ctx = cc.tools.ToolContext.simple(a);
    ctx.artifact_root = root;
    var body = try entry.execute(&ctx, "{}");
    defer body.deinit(a);
    try std.testing.expect(body == .artifact);
    try std.testing.expect(body.artifact.stored.bytes > 17 * 1024 * 1024);
    var first = try cc.tool_result_artifact.readChunk(
        a,
        root,
        body.artifact.stored.id(),
        0,
        128,
    );
    defer first.deinit();
    try std.testing.expect(std.mem.startsWith(u8, first.bytes, "{\"content\""));
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "jsonrpc") == null);
    var rendered = try body.render(a);
    defer rendered.deinit(a);
    try std.testing.expect(rendered.bytes.len < 16 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes, "ReadArtifact") != null);
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

test "MCP: static resource tools preserve byte-zero artifact recovery" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const mock_path: [*:0]const u8 = "zig-out/bin/mock_mcp_server";
    const argv = [_]?[*:0]const u8{ mock_path, null };
    var client = try cc.mcp_client.McpClient.connect(a, argv[0..]);
    defer client.close();

    const server_name = try a.dupe(u8, "mock");
    defer a.free(server_name);
    var entries = [_]cc.mcp_session.McpSessionEntry{.{
        .name = server_name,
        .client = &client,
        .session = cc.mcp_registry_bridge.McpSession.init(a, &client),
    }};
    defer entries[0].session.deinit();
    var sessions: []cc.mcp_session.McpSessionEntry = entries[0..];
    var ctx = cc.tools.ToolContext.simple(a);
    ctx.artifact_root = root;
    ctx.mcp_sessions = &sessions;

    var listed = try cc.tools.dispatch(&ctx, "ListMcpResourcesTool", "{}");
    defer listed.deinit(a);
    switch (listed) {
        .ok => |body| switch (body) {
            .@"inline" => |result| {
                try std.testing.expect(std.mem.indexOf(u8, result.bytes, "mock://large") != null);
                try std.testing.expect(std.mem.indexOf(u8, result.bytes, "\"server\":\"mock\"") != null);
            },
            else => return error.UnexpectedResourceListBody,
        },
        else => return error.UnexpectedResourceListOutcome,
    }

    var read = try cc.tools.dispatch(
        &ctx,
        "ReadMcpResourceTool",
        "{\"uri\":\"mock://large\",\"server\":\"mock\"}",
    );
    defer read.deinit(a);
    const body = switch (read) {
        .ok => |*value| value,
        else => return error.UnexpectedResourceReadOutcome,
    };
    try std.testing.expect(body.* == .artifact);
    try std.testing.expect(body.artifact.stored.bytes > 17 * 1024 * 1024);
    try std.testing.expect(body.artifact.stored.capture_complete);
    var tail = try cc.tool_result_artifact.readChunk(
        a,
        root,
        body.artifact.stored.id(),
        body.artifact.stored.bytes - 64,
        64,
    );
    defer tail.deinit();
    try std.testing.expect(std.mem.indexOf(u8, tail.bytes, "RESOURCE_TAIL") != null);
}
