//! L2 组件测试:ToolDispatcher 单一 metadataFn 解析面(issue #5 验收)。
//!
//! 调度与元数据在结构上不可再脱钩:每个包装层只有一个 per-name 解析函数,
//! 内置身份 / 权限类别 / replay 声明 / 调度标志来自同一次 Entry 查找。
//! 本文件直接消费 metacodes-core 与 AgentCore 包装层(session_budget /
//! mcp_session / model_skill_tool),镜像 abi_v1 Run 面的真实组合。

const std = @import("std");
const core = @import("metacodes-core");
const abi = @import("agentcore-abi");
const harness = @import("harness");

const session_budget = abi.session_budget;
const mcp_session = abi.mcp_session;
const mcp_catalog = abi.mcp_catalog;
const mcp_runtime = abi.mcp_runtime;
const mcp_canonical = abi.mcp_canonical;
const model_skill_tool = abi.model_skill_tool;

const test_rid = core.util_log.RequestId{ .bytes = [_]u8{'0'} ** 12 };

fn openProfile() session_budget.Profile {
    return .{
        .hard_bytes = 64 * 1024 * 1024,
        .soft_bytes = 48 * 1024 * 1024,
        .input_cap_bytes = 8 * 1024 * 1024,
        .provider_request_cap_bytes = 8 * 1024 * 1024,
        .provider_result_cap_bytes = 8 * 1024 * 1024,
        .tool_result_cap_bytes = 2 * 1024 * 1024,
        .mcp_result_cap_bytes = 2 * 1024 * 1024,
        .audit_reserve_bytes = 4096,
        .terminal_reserve_bytes = 1024,
    };
}

/// 预算永不触顶的 Controller:本文件只考 metadata/dispatch 语义,不考预算。
fn openController(allocator: std.mem.Allocator) session_budget.Controller {
    return session_budget.Controller.init(allocator, openProfile(), .{
        .input_delta_bytes = 0,
        .projected_usage_bytes = 256,
        .minimum_required_bytes = 256,
    });
}

test "L2 验收①: budget 包装下内置 Write 仍是内置身份并产出 file_refs" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    var catalog = try core.tool_catalog.Catalog.initBuiltins(a, &.{ "Read", "Write" });
    defer catalog.deinit();
    var selection = try core.tool_catalog.Selection.init(a, &catalog, &.{ "Read", "Write" });
    defer selection.deinit();
    var controller = openController(a);
    var budget = session_budget.ToolEnvironment{
        .controller = &controller,
        .base = .{ .definitions = selection.definitions, .dispatcher = selection.dispatcher() },
    };
    const dispatcher = budget.surface().dispatcher;
    try std.testing.expectEqual(core.tools.ToolExecutorKind.builtin, dispatcher.metadata("Write").?.kind);
    try std.testing.expect(dispatcher.isBuiltin("Write"));

    var ctx = core.tool_context.ToolContext{
        .allocator = a,
        .cwd_abs = root,
        .resolve_relative_paths = true,
        .tool_dispatcher = dispatcher,
    };
    const input = "{\"file_path\":\"budget-ref.txt\",\"content\":\"hello\"}";
    const result = try core.tool_exec.executeOne(&ctx, "Write", input, "budget-write", a, test_rid);
    defer result.freeFileChanges(a);
    switch (result) {
        .done => |done| {
            defer if (done.content) |content| a.free(content);
            defer if (done.file_refs) |refs| {
                for (refs) |*ref| ref.deinit(a);
                a.free(refs);
            };
            try std.testing.expect(!done.is_error);
            // 内置文件工具证据面穿透 budget 包装:file_refs 非空且是 created。
            try std.testing.expect(done.file_refs != null);
            try std.testing.expectEqual(@as(usize, 1), done.file_refs.?.len);
            try std.testing.expectEqualStrings("created", done.file_refs.?[0].kind);
        },
        else => return error.UnexpectedToolOutcome,
    }
}

test "L2 验收①: budget 包装下 denied Write 产生 rejected file_change 记录" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    var catalog = try core.tool_catalog.Catalog.initBuiltins(a, &.{"Write"});
    defer catalog.deinit();
    var selection = try core.tool_catalog.Selection.init(a, &catalog, &.{"Write"});
    defer selection.deinit();
    var controller = openController(a);
    var budget = session_budget.ToolEnvironment{
        .controller = &controller,
        .base = .{ .definitions = selection.definitions, .dispatcher = selection.dispatcher() },
    };
    var ctx = core.tool_context.ToolContext{
        .allocator = a,
        .cwd_abs = root,
        .resolve_relative_paths = true,
        .tool_dispatcher = budget.surface().dispatcher,
    };
    const rejected = core.tool_exec.rejectedFileChanges(
        a,
        &ctx,
        "Write",
        "denied-write",
        "{\"file_path\":\"denied.txt\",\"content\":\"x\"}",
    );
    const records = rejected.records orelse return error.MissingRejectedRecords;
    defer {
        for (records) |*record| record.deinit(a);
        a.free(records);
    }
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqual(core.file_change.Status.rejected, records[0].status);
    try std.testing.expectEqualStrings("Write", records[0].tool);
}

test "L2 验收①: 观察面经 budget 包装看到 Read 的 replay 解析为 read_only" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "wrapped-read.txt",
        .data = "wrapped read fixture",
    });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const path = try std.fmt.allocPrint(a, "{s}/wrapped-read.txt", .{root});
    defer a.free(path);
    const input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\"}}", .{path});
    defer a.free(input);

    var catalog = try core.tool_catalog.Catalog.initBuiltins(a, &.{"Read"});
    defer catalog.deinit();
    var selection = try core.tool_catalog.Selection.init(a, &catalog, &.{"Read"});
    defer selection.deinit();
    var controller = openController(a);
    var budget = session_budget.ToolEnvironment{
        .controller = &controller,
        .base = .{ .definitions = selection.definitions, .dispatcher = selection.dispatcher() },
    };
    const dispatcher = budget.surface().dispatcher;
    try std.testing.expectEqual(core.tools.ReplayDeclaration.read_only, dispatcher.replayDeclaration("Read"));

    // 镜像 tool_observation_test 的 read-replay 断言,但整条路径经过包装:
    // dispatch_started 携带的 resolved policy 必须是 .read_only,而非包装
    // 层丢失声明后的保守 .never。
    const Capture = struct {
        replay: core.execution_effect.ReplayPolicy = .never,
        starts: usize = 0,

        fn sink(self: *@This()) core.tools.ToolObservationSink {
            return .{ .ctx = @ptrCast(self), .emitFn = emit };
        }

        fn emit(raw: *anyopaque, event: core.tools.tool_observation.Event) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .dispatch_started => |started| {
                    self.starts += 1;
                    self.replay = started.replay;
                },
                else => {},
            }
            return true;
        }
    };
    var capture = Capture{};
    var ctx = core.tool_context.ToolContext{
        .allocator = a,
        .tool_dispatcher = dispatcher,
        .tool_observer = capture.sink(),
    };
    const result = try core.tool_exec.executeOne(&ctx, "Read", input, "wrapped-read", a, test_rid);
    defer result.freeFileChanges(a);
    switch (result) {
        .done => |done| {
            defer if (done.content) |content| a.free(content);
            defer if (done.file_refs) |refs| {
                for (refs) |*ref| ref.deinit(a);
                a.free(refs);
            };
            try std.testing.expect(!done.is_error);
        },
        else => return error.UnexpectedToolOutcome,
    }
    try std.testing.expectEqual(@as(usize, 1), capture.starts);
    try std.testing.expect(capture.replay == .read_only);
}

const SameNameHostProbe = struct {
    calls: usize = 0,

    fn execute(
        raw: *anyopaque,
        _: core.tool_catalog.HostRunIdentity,
        args: []const u8,
    ) error{OutOfMemory}!core.tool_catalog.HostToolOutcome {
        const self: *SameNameHostProbe = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .{ .ok = .{ .bytes = args, .release_ctx = raw, .releaseFn = release } };
    }

    fn release(_: *anyopaque, _: []const u8) void {}

    fn tool(self: *SameNameHostProbe, name: []const u8, category: core.tool_context.ToolCategory) core.tool_catalog.HostSyncTool {
        return .{
            .definition = .{
                .name = name,
                .description = "Host-owned same-name tool",
                .input_schema = .{ .type = "object", .required = &.{} },
            },
            .ctx = @ptrCast(self),
            .execute = execute,
            .category = category,
        };
    }
};

test "L2 验收②: 与内置同名的 Host 工具保持宿主身份与声明类别" {
    const a = std.testing.allocator;
    var probe = SameNameHostProbe{};
    var catalog = try core.tool_catalog.Catalog.init(a, &.{}, &.{
        probe.tool("Read", .write),
        probe.tool("Write", .execute),
    });
    defer catalog.deinit();
    var selection = try core.tool_catalog.Selection.init(a, &catalog, &.{ "Read", "Write" });
    defer selection.deinit();
    var controller = openController(a);
    var budget = session_budget.ToolEnvironment{
        .controller = &controller,
        .base = .{ .definitions = selection.definitions, .dispatcher = selection.dispatcher() },
    };
    const dispatcher = budget.surface().dispatcher;

    // 一次解析回答所有查询:kind 是 host,类别是 Host 声明值,绝不是内置。
    try std.testing.expectEqual(core.tools.ToolExecutorKind.host, dispatcher.metadata("Read").?.kind);
    try std.testing.expectEqual(core.tools.ToolExecutorKind.host, dispatcher.metadata("Write").?.kind);
    try std.testing.expect(!dispatcher.isBuiltin("Read"));
    try std.testing.expect(!dispatcher.isBuiltin("Write"));
    try std.testing.expect(dispatcher.isHostSync("Read"));
    try std.testing.expectEqual(core.tool_context.ToolCategory.write, dispatcher.category("Read").?);
    try std.testing.expectEqual(core.tool_context.ToolCategory.execute, dispatcher.category("Write").?);

    var anchor: u8 = 0;
    var ctx = core.tool_context.ToolContext{
        .allocator = a,
        .cwd_abs = ".",
        .tool_dispatcher = dispatcher,
        .host_run = .{
            .identity = .{ .session_id = core.session_id.SessionId.single, .run_id = 1 },
            .host_session_ctx = @ptrCast(&anchor),
        },
    };
    const result = try core.tool_exec.executeOne(&ctx, "Read", "{\"file_path\":\"outside.txt\"}", "host-read", a, test_rid);
    defer result.freeFileChanges(a);
    switch (result) {
        .done => |done| {
            defer if (done.content) |content| a.free(content);
            defer if (done.file_refs) |refs| {
                for (refs) |*ref| ref.deinit(a);
                a.free(refs);
            };
            try std.testing.expect(!done.is_error);
            // 同名不同身份:宿主 Read 不产内置文件工具证据。
            try std.testing.expect(done.file_refs == null);
        },
        else => return error.UnexpectedToolOutcome,
    }
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "L2 验收③: 未解析名 metadata==null → 全部保守派生" {
    const a = std.testing.allocator;
    var catalog = try core.tool_catalog.Catalog.initBuiltins(a, &.{"Read"});
    defer catalog.deinit();
    var selection = try core.tool_catalog.Selection.init(a, &catalog, &.{"Read"});
    defer selection.deinit();
    var controller = openController(a);
    var budget = session_budget.ToolEnvironment{
        .controller = &controller,
        .base = .{ .definitions = selection.definitions, .dispatcher = selection.dispatcher() },
    };
    const dispatcher = budget.surface().dispatcher;
    try std.testing.expect(dispatcher.metadata("Grep") == null);
    try std.testing.expect(!dispatcher.isBuiltin("Grep"));
    try std.testing.expect(!dispatcher.isHostSync("Grep"));
    try std.testing.expect(!dispatcher.prefetchSafe("Grep"));
    try std.testing.expect(dispatcher.category("Grep") == null);
    try std.testing.expectEqual(core.tools.ReplayDeclaration.never, dispatcher.replayDeclaration("Grep"));
}

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"done\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const UNKNOWN_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_unknown\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_unknown\",\"name\":\"Grep\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"pattern\\\":\\\"x\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const ToolResultCapture = struct {
    allocator: std.mem.Allocator,
    content: ?[]u8 = null,

    fn deinit(self: *ToolResultCapture) void {
        if (self.content) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }

    fn backend(self: *ToolResultCapture) core.protocol.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }

    fn emit(raw: *anyopaque, _: core.session_id.SessionId, event: core.protocol.ui_event.CoreEvent) void {
        const self: *ToolResultCapture = @ptrCast(@alignCast(raw));
        switch (event) {
            .tool_result => |result| if (std.mem.eql(u8, result.name, "Grep") and self.content == null) {
                self.content = self.allocator.dupe(u8, result.content) catch null;
            },
            else => {},
        }
    }

    fn poll(_: *anyopaque, _: core.session_id.SessionId) ?core.protocol.ui_event.UiEvent {
        return null;
    }
};

/// 分类层验收:dispatcher 在场时,目录无法解析的名字按 .execute 分类
/// (plan deny / default ask),绝不落回按名字猜 .read 的 legacy 兜底。
fn runUnknownNameClassification(
    mode: core.types.PermissionMode,
) !struct { content: []u8, allocator: std.mem.Allocator } {
    const a = std.testing.allocator;
    const responses = [_][]const u8{ UNKNOWN_TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&responses, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = core.client.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conversation = core.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "call the unresolvable tool");

    var catalog = try core.tool_catalog.Catalog.initBuiltins(a, &.{"Read"});
    defer catalog.deinit();
    var selection = try core.tool_catalog.Selection.init(a, &catalog, &.{"Read"});
    defer selection.deinit();

    var permission = core.permission.createContext(mode, a);
    // 无 UI 的 ask 必须 fail-closed 拒绝,而不是读 fd 0。
    permission.no_interactive_prompt = true;
    var capture = ToolResultCapture{ .allocator = a };
    errdefer capture.deinit();
    const backend = capture.backend();
    const result = try core.agent_loop.run(
        &conversation,
        client.provider(),
        selection.definitions,
        &permission,
        .{
            .max_turns = 4,
            .tool_dispatcher = selection.dispatcher(),
            .emit_tool_cards = true,
            .colorize = false,
        },
        &backend,
        a,
    );
    try std.testing.expectEqual(core.agent_loop.StopReason.end_turn, result.stop_reason);
    const content = capture.content orelse return error.MissingToolResult;
    capture.content = null;
    return .{ .content = content, .allocator = a };
}

test "L2 验收③: dispatcher 在场的未知名在 plan 模式被 deny" {
    var run = try runUnknownNameClassification(.plan);
    defer run.allocator.free(run.content);
    // .execute 分类 → plan deny;若错落 legacy unknown-read 会被 allow 并
    // 执行出 "does not exist" 的 UnknownTool 引导。
    try std.testing.expect(std.mem.indexOf(u8, run.content, "permission_denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.content, "denied by permission rule or plan mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.content, "does not exist") == null);
}

test "L2 验收③: dispatcher 在场的未知名在 default 模式走 ask" {
    var run = try runUnknownNameClassification(.default);
    defer run.allocator.free(run.content);
    // .execute 分类 → default ask → 无 UI fail-closed 拒绝("user declined")。
    // 绝不是 .read → allow → 执行到 UnknownTool 引导。
    try std.testing.expect(std.mem.indexOf(u8, run.content, "user declined") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.content, "does not exist") == null);
}

/// 精简版 in-memory MCP peer(镜像 src/agentcore/mcp_test_support.zig 的
/// modern-era 子集;该 fixture 不在库导出面上,组件测试自带一份)。
const FixtureMcpServer = struct {
    ttl_ms: u64 = 60_000,
    calls: u32 = 0,

    const Connection = struct { owner: *FixtureMcpServer };

    fn connector(self: *FixtureMcpServer) mcp_runtime.Connector {
        return .{ .ctx = self, .open_fn = open };
    }

    fn open(
        raw: *anyopaque,
        _: mcp_runtime.ConnectionPurpose,
        requested_era: mcp_canonical.Era,
    ) anyerror!mcp_runtime.OpenOutcome {
        const self: *FixtureMcpServer = @ptrCast(@alignCast(raw));
        if (requested_era != .modern_2026_07_28) return .network_error;
        const connection = try std.heap.c_allocator.create(Connection);
        connection.* = .{ .owner = self };
        return .{ .connection = .{
            .ctx = connection,
            .request_fn = request,
            .tool_request = .{ .completed = request },
            .notify_fn = notify,
            .close_fn = close,
        } };
    }

    fn request(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        encoded: []const u8,
        _: u32,
        _: mcp_runtime.Cancellation,
    ) anyerror!mcp_runtime.ExchangeOutcome {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        const self = connection.owner;
        const id = requestId(encoded) orelse return .server_error;
        const response = if (std.mem.indexOf(u8, encoded, "server/discover") != null)
            try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{{}},\"ttlMs\":{d},\"cacheScope\":\"private\"}}}}",
                .{ id, self.ttl_ms },
            )
        else if (std.mem.indexOf(u8, encoded, "initialize") != null)
            try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"2026-07-28\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"metadata-test\",\"version\":\"1\"}}}}}}",
                .{id},
            )
        else if (std.mem.indexOf(u8, encoded, "tools/list") != null)
            try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"city\":{{\"type\":\"string\"}}}},\"required\":[\"city\"],\"additionalProperties\":false}}}}],\"ttlMs\":{d},\"cacheScope\":\"private\"}}}}",
                .{ id, self.ttl_ms },
            )
        else if (std.mem.indexOf(u8, encoded, "tools/call") != null) blk: {
            self.calls += 1;
            break :blk try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[],\"structuredContent\":{{\"ok\":true}}}}}}",
                .{id},
            );
        } else return .server_error;
        return .{ .response = .{ .http_status = 0, .body = response } };
    }

    fn notify(_: *anyopaque, _: []const u8, _: u32, _: mcp_runtime.Cancellation) anyerror!void {}

    fn close(raw: *anyopaque) void {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        std.heap.c_allocator.destroy(connection);
    }

    fn requestId(encoded: []const u8) ?u64 {
        const marker = "\"id\":";
        const start = (std.mem.indexOf(u8, encoded, marker) orelse return null) + marker.len;
        var end = start;
        while (end < encoded.len and std.ascii.isDigit(encoded[end])) : (end += 1) {}
        return std.fmt.parseInt(u64, encoded[start..end], 10) catch null;
    }
};

test "L2 验收④: budget∘skill∘mcp∘Selection 一次解析贯穿全栈且 Read 仍执行内置" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "composed-read.txt",
        .data = "composed-read-fixture",
    });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const path = try std.fmt.allocPrint(a, "{s}/composed-read.txt", .{root});
    defer a.free(path);
    const read_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\"}}", .{path});
    defer a.free(read_input);

    // 底层 Selection:内置 Read + 声明为 .write 的 Host 工具。
    var probe = SameNameHostProbe{};
    var catalog = try core.tool_catalog.Catalog.init(a, &.{"Read"}, &.{
        probe.tool("HostEcho", .write),
    });
    defer catalog.deinit();
    var selection = try core.tool_catalog.Selection.init(a, &catalog, &.{ "Read", "HostEcho" });
    defer selection.deinit();
    // skill 层之下:Selection 对内置 Read 保留 prefetch。
    try std.testing.expect(selection.dispatcher().metadata("Read").?.prefetch_safe);

    // MCP 层(真实 View + Environment,镜像 abi_v1 的 Run 面组合)。
    var server = FixtureMcpServer{};
    const binding = [_]u8{0x5A} ** 32;
    const specs = [_]mcp_catalog.ServerSpec{.{
        .binding = binding,
        .namespace = "weather",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "metadata-test", .version = "1" },
    }};
    var manager = try mcp_catalog.Manager.init(a, &specs, .{});
    defer manager.deinit();
    _ = try manager.refresh();
    const snapshot = try manager.retainCurrent();
    defer snapshot.release();
    var view = try mcp_session.View.init(a, snapshot, &.{.{
        .server_binding_identity = binding,
        .tool_name = "weather",
    }}, .fresh);
    defer view.deinit();
    var mcp_environment = try mcp_session.Environment.init(
        a,
        &view,
        selection.definitions,
        selection.dispatcher(),
        null,
    );
    defer mcp_environment.deinit();
    const model_name = view.entries[0].model_name;

    // Skill overlay(镜像其 in-file 测试的最小构造:metadata/dispatch 只依赖
    // base_dispatcher / base_definitions / definitions;invokeSkill 的
    // SkillNotFound 早退还会摸 allocator 与 snapshot,故一并给真值)。
    var no_definitions = [_]core.json.ToolDefinition{};
    var skill_snapshot = core.skills_runtime.catalog.Snapshot{
        .owner_allocator = a,
        .arena = std.heap.ArenaAllocator.init(a),
        .scope_id = [_]u8{'a'} ** 64,
        .revision = [_]u8{'b'} ** 64,
        .health = .healthy,
        .skills = &.{},
        .issues = &.{},
        .descriptor_json = "",
        .content_bytes = 0,
        .resident_bytes = 0,
    };
    defer skill_snapshot.arena.deinit();
    var skill_environment: model_skill_tool.Environment = undefined;
    skill_environment.allocator = a;
    skill_environment.snapshot = &skill_snapshot;
    skill_environment.base_definitions = mcp_environment.surface().definitions;
    skill_environment.base_dispatcher = mcp_environment.surface().dispatcher;
    skill_environment.definitions = &no_definitions;

    var controller = openController(a);
    var budget = session_budget.ToolEnvironment{
        .controller = &controller,
        .base = skill_environment.surface(),
    };
    const dispatcher = budget.surface().dispatcher;

    // 同一条解析链回答每类名字的每个查询。
    try std.testing.expectEqual(core.tools.ToolExecutorKind.builtin, dispatcher.metadata("Read").?.kind);
    try std.testing.expectEqual(core.tools.ReplayDeclaration.read_only, dispatcher.replayDeclaration("Read"));
    try std.testing.expectEqual(core.tool_context.ToolCategory.write, dispatcher.category("HostEcho").?);
    try std.testing.expectEqual(core.tools.ToolExecutorKind.host, dispatcher.metadata("HostEcho").?.kind);
    try std.testing.expectEqual(core.tool_context.ToolCategory.execute, dispatcher.category(model_name).?);
    try std.testing.expectEqual(core.tools.ToolExecutorKind.external, dispatcher.metadata(model_name).?.kind);
    try std.testing.expectEqual(core.tool_context.ToolCategory.read, dispatcher.category(model_skill_tool.TOOL_NAME).?);
    // skill 层整体禁 prefetch:上方看到 false,底层 Selection 仍是 true。
    try std.testing.expect(!dispatcher.metadata("Read").?.prefetch_safe);
    try std.testing.expect(!dispatcher.prefetchSafe("Read"));
    // 未解析名跨全栈仍是 null。
    try std.testing.expect(dispatcher.metadata("Grep") == null);
    // 组合面结构自检:每个 nameAt 枚举出的名字都有 metadata 覆盖——未来任何
    // 包装层新增可派发名却漏掉 metadata 分支,这里(与 abi_v1 Debug 组合点)先红。
    try std.testing.expect(dispatcher.validateMetadataCoverage() == null);

    // dispatch("Read") 穿过 budget→skill→mcp→Selection 执行真实内置 Read。
    var ctx = core.tool_context.ToolContext{
        .allocator = a,
        .tool_dispatcher = dispatcher,
        .artifact_root = root,
    };
    var outcome = try dispatcher.dispatch(&ctx, "Read", read_input);
    defer outcome.deinit(a);
    try std.testing.expect(outcome == .ok);
    var rendered = try outcome.ok.render(a);
    defer rendered.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes, "composed-read-fixture") != null);

    // dispatch(MCP 别名) 穿过同一全栈落到 MCP 执行路径:connector 侧效应
    // (fixture 计数)证明不是被中间层吞掉或改道。
    try std.testing.expectEqual(@as(u32, 0), server.calls);
    var mcp_outcome = try dispatcher.dispatch(&ctx, model_name, "{\"city\":\"Paris\"}");
    defer mcp_outcome.deinit(a);
    try std.testing.expect(mcp_outcome == .ok);
    try std.testing.expectEqual(@as(u32, 1), server.calls);

    // dispatch("Skill") 由 skill 层拦截:空 catalog 下未知 skill 名报
    // SkillNotFound——若名字漏到底层 Selection 只会是 UnknownTool。
    try std.testing.expectError(
        error.SkillNotFound,
        dispatcher.dispatch(&ctx, model_skill_tool.TOOL_NAME, "{\"name\":\"no-such-skill\"}"),
    );

    // metadata==null ⇒ dispatch UnknownTool,经包装全栈成立,不只裸 Selection。
    try std.testing.expectError(
        error.UnknownTool,
        dispatcher.dispatch(&ctx, "Grep", "{\"pattern\":\"x\"}"),
    );
}

// ── 图片 tool_result 穿过 budget 包装:不 promoteInline,cap 按视觉估算记 ──────────────
//
// Conversation 投影豁免图片(result_projection.isImageResult),budget 包装是投影之前
// 唯一另一个按字节改写 inline 结果的层:超过 tool_result_cap_bytes 的 Read 图片若在这里
// 被转成 artifact,方言层看到的就是信封而不是图。

/// cap 压到 8 KiB:高于一张图片按视觉估算记的 IMAGE_RESULT_BUDGET_BYTES(6400,否则
/// 任何图片都会被 settleSuccess 判资源超限——cap 小于单图记账值是配置错误),低于夹具尺寸。
const TIGHT_CAP: u64 = 8 * 1024;

fn tightProfile() session_budget.Profile {
    var profile = openProfile();
    profile.tool_result_cap_bytes = TIGHT_CAP;
    return profile;
}

const BudgetRead = struct { content: []u8, is_error: bool };

/// 经 budget 包装读 `name`,返回 owned 的 done.content(调用方 free)与 is_error。
fn readThroughBudget(a: std.mem.Allocator, root: []const u8, controller: *session_budget.Controller, name: []const u8) !BudgetRead {
    var catalog = try core.tool_catalog.Catalog.initBuiltins(a, &.{"Read"});
    defer catalog.deinit();
    var selection = try core.tool_catalog.Selection.init(a, &catalog, &.{"Read"});
    defer selection.deinit();
    var budget = session_budget.ToolEnvironment{
        .controller = controller,
        .base = .{ .definitions = selection.definitions, .dispatcher = selection.dispatcher() },
    };
    var ctx = core.tool_context.ToolContext{
        .allocator = a,
        .cwd_abs = root,
        .artifact_root = root,
        .resolve_relative_paths = true,
        .tool_dispatcher = budget.surface().dispatcher,
    };
    const input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\"}}", .{name});
    defer a.free(input);
    const result = try core.tool_exec.executeOne(&ctx, "Read", input, "budget-read", a, test_rid);
    defer result.freeFileChanges(a);
    switch (result) {
        .done => |done| {
            defer if (done.file_refs) |refs| {
                for (refs) |*ref| ref.deinit(a);
                a.free(refs);
            };
            return .{ .content = done.content orelse return error.MissingContent, .is_error = done.is_error };
        },
        else => return error.UnexpectedToolOutcome,
    }
}

test "L2 budget 包装:超过 tool_result_cap 的 Read 图片保持 inline 图像,同尺寸文本照常 promote" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    // 9000 原始字节 → 12000 base64:高于 8 KiB 的 cap。
    const raw = try a.alloc(u8, 9000);
    defer a.free(raw);
    for (raw, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 7);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.png", .data = raw });
    // 多行文本(Read 会截断超长单行,单行夹具到不了 cap):300 行 × 41 字节 ≈ 12.3 KB。
    const txt = try a.alloc(u8, 300 * 41);
    defer a.free(txt);
    for (0..300) |line| {
        @memset(txt[line * 41 .. line * 41 + 40], 'x');
        txt[line * 41 + 40] = '\n';
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.txt", .data = txt });

    var controller = session_budget.Controller.init(a, tightProfile(), .{
        .input_delta_bytes = 0,
        .projected_usage_bytes = 256,
        .minimum_required_bytes = 256,
    });

    // 正向:图片结果原样 inline,方言层仍能识别为图像;没有投影信封。
    const image_read = try readThroughBudget(a, root, &controller, "big.png");
    defer a.free(image_read.content);
    try std.testing.expect(!image_read.is_error);
    const image = image_read.content;
    try std.testing.expect(core.result_projection.IMAGE_RESULT_BUDGET_BYTES < TIGHT_CAP);
    try std.testing.expect(image.len > TIGHT_CAP);
    try std.testing.expect(core.result_projection.isImageResult(image));
    try std.testing.expect(std.mem.indexOf(u8, image, core.result_projection.SCHEMA) == null);
    const encoder = std.base64.standard.Encoder;
    const expected_b64 = try a.alloc(u8, encoder.calcSize(raw.len));
    defer a.free(expected_b64);
    _ = encoder.encode(expected_b64, raw);
    try std.testing.expect(std.mem.indexOf(u8, image, expected_b64) != null);
    // 耐久预算按真实字节记(checkpoint 真的要存这么多),不是按 6400 的视觉估算。
    try std.testing.expect(controller.estimated_usage_bytes >= image.len);

    // 反向:同尺寸文本结果仍被 cap 兜住,promote 成 artifact 信封。
    const text_read = try readThroughBudget(a, root, &controller, "big.txt");
    defer a.free(text_read.content);
    try std.testing.expect(!text_read.is_error);
    const text = text_read.content;
    try std.testing.expect(!core.result_projection.isImageResult(text));
    try std.testing.expect(text.len < TIGHT_CAP);
    try std.testing.expect(std.mem.indexOf(u8, text, core.result_projection.SCHEMA) != null or core.result_projection.hasRecoverableArtifact(text));
}

test "L2 budget 包装:cap 低于 IMAGE_RESULT_BUDGET_BYTES 时图片按 6400 记账被 cap 拒绝,required_checkpoint_bytes 恰为 6400" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const raw = try a.alloc(u8, 9000);
    defer a.free(raw);
    for (raw, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% 3);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.png", .data = raw });

    var profile = openProfile();
    profile.tool_result_cap_bytes = core.result_projection.IMAGE_RESULT_BUDGET_BYTES - 1;
    var controller = session_budget.Controller.init(a, profile, .{
        .input_delta_bytes = 0,
        .projected_usage_bytes = 256,
        .minimum_required_bytes = 256,
    });
    const read = try readThroughBudget(a, root, &controller, "big.png");
    defer a.free(read.content);
    // 结果是有界的 resource-limit 标记,不是图片,也不是信封。
    try std.testing.expect(read.is_error);
    try std.testing.expect(std.mem.indexOf(u8, read.content, "checkpoint_payload_resource_limit") != null);
    try std.testing.expect(!core.result_projection.isImageResult(read.content));
    // 宿主可见的 requirement 就是那 6400 字节的图片记账值(per-operation cap 分支的约定)。
    try std.testing.expectEqual(session_budget.Outcome.resource_limit, controller.outcome());
    try std.testing.expectEqual(@as(u64, core.result_projection.IMAGE_RESULT_BUDGET_BYTES), controller.requiredBytes());
}
