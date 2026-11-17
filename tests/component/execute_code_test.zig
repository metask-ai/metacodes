//! Actual provider requests -> AgentLoop -> QuickJS -> gated tools -> next request.
const std = @import("std");
const cc = @import("cc");
const harness = @import("harness");

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"done\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const Script = struct { code: []const u8, timeout_ms: u32 = 30000 };
const Evidence = struct {
    result: cc.agent_loop.RunResult,
    request: []u8,
    changes: usize,
    inner_results: usize,
    fn deinit(self: Evidence, gpa: std.mem.Allocator) void {
        gpa.free(self.request);
    }
};

const Capture = struct {
    changes: usize = 0,
    inner_results: usize = 0,
    fn emit(raw: *anyopaque, _: cc.session_id.SessionId, event: cc.ui_event.CoreEvent) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .file_changes => |changes| {
                self.changes += changes.changes.len;
            },
            .tool_result => |result| {
                if (std.mem.indexOf(u8, result.id, "/js/") != null) self.inner_results += 1;
            },
            else => {},
        }
    }
    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

fn run(conversation: *cc.conversation.Conversation, scripts: []const Script, permission: *cc.permission.PermissionContext, options: cc.agent_loop.Options) !Evidence {
    const gpa = conversation.allocator;
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const responses = try arena.alloc([]const u8, scripts.len + 1);
    for (scripts, 0..) |script, index| {
        const input = try std.json.Stringify.valueAlloc(arena, script, .{});
        const encoded = try std.json.Stringify.valueAlloc(arena, input, .{});
        responses[index] = try std.fmt.allocPrint(arena, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"tool\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"code{d}\",\"name\":\"ExecuteCode\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n", .{ index, encoded });
    }
    responses[scripts.len] = FINAL_SSE;
    var server = try harness.MockServer.startCassette(responses, 0);
    defer server.stop();
    const url = try server.urlOwned(gpa);
    defer gpa.free(url);
    var io = @import("platform").signal.threadedIo(gpa, .{});
    defer io.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(gpa, io.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    const defs = try cc.tools.toToolDefinitions(gpa);
    defer gpa.free(defs);
    var opts = options;
    opts.max_turns = 12;
    opts.colorize = false;
    opts.emit_tool_cards = true;
    var capture = Capture{};
    const backend = cc.ui_backend.UiBackend{ .ctx = &capture, .emit = Capture.emit, .poll = Capture.poll };
    if (conversation.messages.items.len == 0) try conversation.appendText(.user, "run the JavaScript");
    const result = try cc.agent_loop.run(conversation, client.provider(), opts.tool_defs orelse defs, permission, opts, &backend, gpa);
    return .{ .result = result, .request = try gpa.dupe(u8, server.lastRequest().?.body()), .changes = capture.changes, .inner_results = capture.inner_results };
}

fn resultAt(conversation: *const cc.conversation.Conversation, index: usize) !cc.message.ToolResult {
    var seen: usize = 0;
    for (conversation.messages.items) |message| for (message.blocks) |block| {
        if (block == .tool_result) {
            if (seen == index) return block.tool_result;
            seen += 1;
        }
    };
    return error.MissingResult;
}

fn expectContains(bytes: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, bytes, needle) == null) {
        std.debug.print("expected {s} in {s}\n", .{ needle, bytes });
        return error.MissingExpectedContent;
    }
}

test "ExecuteCode L2 persists globals across turns and Runs, isolates conversations" {
    const gpa = std.testing.allocator;
    var conversation = cc.conversation.Conversation.init(gpa);
    defer conversation.deinit();
    var permission = cc.permission.createContext(.bypass_permissions, gpa);
    const first = try run(&conversation, &.{
        .{ .code = "var saved = {count: 40}; let lexical = 1; const fixed = 1; console.log('retained'); saved.count" },
        .{ .code = "saved.count += lexical + fixed; saved.count" },
    }, &permission, .{});
    defer first.deinit(gpa);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, first.result.stop_reason);
    try expectContains((try resultAt(&conversation, 1)).content, "\"value\":42");
    try expectContains((try resultAt(&conversation, 0)).content, "retained");
    const second = try run(&conversation, &.{.{ .code = "saved.count += 1; saved.count" }}, &permission, .{});
    defer second.deinit(gpa);
    try expectContains((try resultAt(&conversation, 2)).content, "\"value\":43");
    var isolated = cc.conversation.Conversation.init(gpa);
    defer isolated.deinit();
    const other = try run(&isolated, &.{.{ .code = "typeof saved" }}, &permission, .{});
    defer other.deinit(gpa);
    try expectContains((try resultAt(&isolated, 0)).content, "undefined");
}

test "ExecuteCode L2 writes and reads through native tools with evidence and selected output" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    const path = try std.fmt.allocPrint(gpa, "{s}/bridge.txt", .{root});
    defer gpa.free(path);
    const encoded_path = try std.json.Stringify.valueAlloc(gpa, path, .{});
    defer gpa.free(encoded_path);
    const source = try std.fmt.allocPrint(gpa, "await tools.Write({{file_path:{s},content:'HIDDEN_INTERMEDIATE'}}); var body = await tools.Read({{file_path:{s}}}); ({{length:JSON.stringify(body).length}})", .{ encoded_path, encoded_path });
    defer gpa.free(source);
    var conversation = cc.conversation.Conversation.init(gpa);
    defer conversation.deinit();
    var permission = cc.permission.createContext(.bypass_permissions, gpa);
    var reads = cc.core_read_state.ReadState.init(gpa);
    defer reads.deinit();
    const evidence = try run(&conversation, &.{.{ .code = source }}, &permission, .{ .read_state = &reads, .cwd_abs = root });
    defer evidence.deinit(gpa);
    const result = try resultAt(&conversation, 0);
    try std.testing.expect(!result.is_error);
    try expectContains(result.content, "\"tool_calls\":2");
    try std.testing.expectEqual(@as(u32, 3), evidence.result.tool_calls);
    try std.testing.expect(evidence.changes > 0);
    try std.testing.expectEqual(@as(usize, 2), evidence.inner_results);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "bridge.txt", gpa, .limited(1024));
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("HIDDEN_INTERMEDIATE", bytes);
    // The source is visible, but no inner tool_use/result is appended to history.
    try std.testing.expectError(error.MissingResult, resultAt(&conversation, 1));
    try std.testing.expect(std.mem.indexOf(u8, evidence.request, "code0/js/") == null);
}

test "ExecuteCode L2 nested permissions, schema validation and recursion fail closed" {
    const gpa = std.testing.allocator;
    var conversation = cc.conversation.Conversation.init(gpa);
    defer conversation.deinit();
    var permission = cc.permission.createContext(.default, gpa);
    permission.no_interactive_prompt = true;
    const evidence = try run(&conversation, &.{
        .{ .code = "try { await tools.Bash({command:'sh -c echo'}); } catch(e) { e.result; }" },
        .{ .code = "try { await tools.Read({file_path:42}); } catch(e) { e.result; }" },
        .{ .code = "try { await tools.ExecuteCode({code:'1'}); } catch(e) { e.result; }" },
    }, &permission, .{});
    defer evidence.deinit(gpa);
    try expectContains((try resultAt(&conversation, 0)).content, "permission_denied");
    try expectContains((try resultAt(&conversation, 1)).content, "invalid_args");
    try expectContains((try resultAt(&conversation, 2)).content, "unavailable inside this script");
}

test "ExecuteCode L2 PreToolUse rewrites, blocks, and PostToolUse reaches provider" {
    const gpa = std.testing.allocator;
    const pre = [_]cc.permission_hooks.HookEntry{
        .{ .matcher = "Read", .commands = &.{"echo '{\"updatedInput\":{\"file_path\":42}}'"} },
        .{ .matcher = "Write", .commands = &.{"echo '{\"decision\":\"block\"}'"} },
    };
    const post = [_]cc.permission_hooks.HookEntry{
        .{ .matcher = "Read", .commands = &.{"echo '{\"additionalContext\":\"INNER_POST_CONTEXT\"}'"} },
    };
    const hooks = cc.permission_hooks.HookSet{ .allocator = gpa, .pre_tool_use = &pre, .post_tool_use = &post };
    var permission = cc.permission.createContext(.bypass_permissions, gpa);
    permission.hooks = &hooks;
    var conversation = cc.conversation.Conversation.init(gpa);
    defer conversation.deinit();
    const evidence = try run(&conversation, &.{
        .{ .code = "try { await tools.Read({file_path:'not-used'}); } catch(e) { e.result; }" },
        .{ .code = "try { await tools.Write({file_path:'not-used',content:'x'}); } catch(e) { e.result; }" },
    }, &permission, .{});
    defer evidence.deinit(gpa);
    try expectContains((try resultAt(&conversation, 0)).content, "invalid_args");
    try expectContains((try resultAt(&conversation, 1)).content, "blocked by PreToolUse hook");
    try expectContains(evidence.request, "INNER_POST_CONTEXT");
}

test "ExecuteCode L2 timeout, unresolved promises, output limits reset the VM" {
    const gpa = std.testing.allocator;
    var permission = cc.permission.createContext(.bypass_permissions, gpa);
    var conversation = cc.conversation.Conversation.init(gpa);
    defer conversation.deinit();
    const evidence = try run(&conversation, &.{
        .{ .code = "var abandoned = 1; for(;;) {}", .timeout_ms = 10 },
        .{ .code = "typeof abandoned" },
        .{ .code = "await new Promise(() => {})" },
        .{ .code = "'x'.repeat(100000)" },
        .{ .code = "[typeof process,typeof require,typeof fetch,typeof std,typeof os,typeof Atomics]" },
    }, &permission, .{});
    defer evidence.deinit(gpa);
    try std.testing.expect((try resultAt(&conversation, 0)).is_error);
    try expectContains((try resultAt(&conversation, 0)).content, "CodeTimeout");
    try expectContains((try resultAt(&conversation, 1)).content, "undefined");
    try expectContains((try resultAt(&conversation, 2)).content, "UnresolvedPromise");
    try std.testing.expect((try resultAt(&conversation, 3)).is_error);
    try std.testing.expect(!(try resultAt(&conversation, 4)).is_error);
}

test "ExecuteCode L2 unawaited calls never run after a script completes" {
    const gpa = std.testing.allocator;
    var permission = cc.permission.createContext(.bypass_permissions, gpa);
    var conversation = cc.conversation.Conversation.init(gpa);
    defer conversation.deinit();
    const evidence = try run(&conversation, &.{
        .{ .code = "tools.Read({file_path:'must-not-run'}); 1" },
        .{ .code = "({toJSON(){tools.Read({file_path:'must-not-run'}); return 1;}})" },
        .{ .code = "1" },
    }, &permission, .{});
    defer evidence.deinit(gpa);
    try std.testing.expect((try resultAt(&conversation, 0)).is_error);
    try std.testing.expect((try resultAt(&conversation, 1)).is_error);
    try std.testing.expectEqual(@as(usize, 0), evidence.inner_results);
    try std.testing.expect(!(try resultAt(&conversation, 2)).is_error);
}

test "ExecuteCode L2 Promise.all returns parsed results and bounds tool count" {
    const gpa = std.testing.allocator;
    var permission = cc.permission.createContext(.bypass_permissions, gpa);
    var conversation = cc.conversation.Conversation.init(gpa);
    defer conversation.deinit();
    const evidence = try run(&conversation, &.{
        .{ .code = "var errors = await Promise.all([tools.Read({file_path:1}).catch(e=>e.result.error.code), tools.Read({file_path:2}).catch(e=>e.result.error.code)]); errors" },
        .{ .code = "for(var i=0;i<129;i++) await tools.Read({file_path:1}).catch(()=>null); i" },
    }, &permission, .{});
    defer evidence.deinit(gpa);
    try expectContains((try resultAt(&conversation, 0)).content, "[\"invalid_args\",\"invalid_args\"]");
    try expectContains((try resultAt(&conversation, 0)).content, "\"tool_calls\":2");
    try expectContains((try resultAt(&conversation, 1)).content, "\"tool_calls\":128");
    try std.testing.expectEqual(@as(usize, 130), evidence.inner_results);
}

test "ExecuteCode L2 saved functions lose removed menu capabilities on next Run" {
    const gpa = std.testing.allocator;
    var permission = cc.permission.createContext(.bypass_permissions, gpa);
    var conversation = cc.conversation.Conversation.init(gpa);
    defer conversation.deinit();
    const first = try run(&conversation, &.{.{ .code = "var later = () => tools.Read({file_path:42}); 1" }}, &permission, .{});
    defer first.deinit(gpa);
    var catalog = try cc.tool_catalog.Catalog.initBuiltins(gpa, &.{"ExecuteCode"});
    defer catalog.deinit();
    var selected = try cc.tool_catalog.Selection.init(gpa, &catalog, &.{"ExecuteCode"});
    defer selected.deinit();
    const second = try run(&conversation, &.{.{ .code = "try { await later(); } catch(e) { e.result.error.code; }" }}, &permission, .{ .tool_defs = selected.definitions, .tool_dispatcher = selected.dispatcher() });
    defer second.deinit(gpa);
    try expectContains((try resultAt(&conversation, 1)).content, "permission_denied");
}

test "ExecuteCode L2 Host fatal cannot be caught and stops subsequent calls" {
    const gpa = std.testing.allocator;
    const Probe = struct {
        calls: usize = 0,
        fn execute(raw: *anyopaque, _: cc.tool_catalog.HostRunIdentity, _: []const u8) error{OutOfMemory}!cc.tool_catalog.HostToolOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .fatal;
        }
    };
    var probe = Probe{};
    const tool = cc.tool_catalog.HostSyncTool{
        .ctx = &probe,
        .execute = Probe.execute,
        .definition = .{ .name = "HostFatal", .description = "fatal", .input_schema = .{ .type = "object" } },
    };
    var catalog = try cc.tool_catalog.Catalog.init(gpa, &.{"ExecuteCode"}, &.{tool});
    defer catalog.deinit();
    var selected = try cc.tool_catalog.Selection.init(gpa, &catalog, &.{ "ExecuteCode", "HostFatal" });
    defer selected.deinit();
    var permission = cc.permission.createContext(.bypass_permissions, gpa);
    var conversation = cc.conversation.Conversation.init(gpa);
    defer conversation.deinit();
    try std.testing.expectError(error.HostToolFatal, run(&conversation, &.{.{ .code = "try { await tools.HostFatal({}); } catch(e) {} await tools.HostFatal({});" }}, &permission, .{ .tool_defs = selected.definitions, .tool_dispatcher = selected.dispatcher(), .host_run = .{
        .identity = .{ .session_id = cc.session_id.SessionId.single, .run_id = 1 },
        .host_session_ctx = &probe,
    } }));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectError(error.MissingResult, resultAt(&conversation, 0));
}

test "ExecuteCode L2 heap, stack and diagnostic bounds survive hostile scripts" {
    const gpa = std.testing.allocator;
    var permission = cc.permission.createContext(.bypass_permissions, gpa);
    var conversation = cc.conversation.Conversation.init(gpa);
    defer conversation.deinit();
    const evidence = try run(&conversation, &.{
        .{ .code = "new ArrayBuffer(128 * 1024 * 1024)" },
        .{ .code = "function deep(){return deep()} deep()" },
        .{ .code = "throw '诊'.repeat(20000)" },
        .{ .code = "42" },
    }, &permission, .{});
    defer evidence.deinit(gpa);
    for (0..3) |index| try std.testing.expect((try resultAt(&conversation, index)).is_error);
    try std.testing.expect((try resultAt(&conversation, 2)).content.len < 9 * 1024);
    try expectContains((try resultAt(&conversation, 3)).content, "\"value\":42");
}
