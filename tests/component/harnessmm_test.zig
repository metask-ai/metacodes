//! L2: omitted callbacks still consume the ordinary AgentLoop turn budget.
const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const PLAN = cc.harnessmm.OPEN ++
    \\{"schema_version":1,"root":{"tool":"Bash","arguments":{"command":"printf root"}},"nodes":[{"id":"A","after":"root","tool":"Bash","arguments":{"command":"printf one"},"guard":{"kind":"exit_zero"}},{"id":"B","after":"A","tool":"Bash","arguments":{"command":"printf two"},"guard":{"kind":"exit_zero"}}]}
++ cc.harnessmm.CLOSE;

fn rootResponse(a: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n");
    try w.writeAll("data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n");
    try w.print("data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{f}}}}}\n\n", .{std.json.fmt(PLAN, .{})});
    try w.writeAll("data: {\"type\":\"content_block_stop\",\"index\":0}\n\n");
    try w.writeAll("data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"root_call\",\"name\":\"Bash\",\"input\":{}}}\n\n");
    try w.print("data: {{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{f}}}}}\n\n", .{std.json.fmt("{\"command\":\"printf root\"}", .{})});
    try w.writeAll("data: {\"type\":\"content_block_stop\",\"index\":1}\n\n");
    try w.writeAll("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\ndata: {\"type\":\"message_stop\"}\n\n");
    return out.toOwnedSlice();
}

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"done\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\ndata: {\"type\":\"message_stop\"}\n\n";
const MODEL = "claude-sonnet-4-20250514";
const INSTRUCTION = "RSI preview fixture";

fn policy(hash: []const u8) cc.skill_rsi.Policy {
    return .{
        .schema_version = 1,
        .feature_schema = cc.skill_rsi.FEATURE_SCHEMA,
        .model = MODEL,
        .seed = .{ .instruction = INSTRUCTION, .sha256 = hash, .router = .{
            .instruction_sha256 = hash,
            .intercept = 1,
            .weights = .{ 0, 0, 0, 0, 0 },
            .threshold = 0.5,
            .minimum = .{ 0, 0, 0, 0, 0 },
            .maximum = .{ 100, 100, 1, 1, 1 },
        } },
    };
}

const Route = enum { root, child, background };

fn checkPreviewRoute(route: Route, preview: bool) !void {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX fixture commands
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    const response = try rootResponse(a);
    defer a.free(response);
    var server = try harness.MockServer.startCassette(&.{ response, FINAL_SSE }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io = @import("platform").signal.threadedIo(a, .{});
    defer io.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io.io(), "test-key", MODEL, url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "read before editing");
    var permission = cc.permission.createContext(.bypass_permissions, a);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var render = cc.writer_backend.WriterBackend.initNull();
    const backend = render.backend();
    const hash = cc.harnessmm.sha256(INSTRUCTION);
    const frozen = policy(&hash);
    try frozen.validate();
    // Disabled runs deliberately have neither usable policy nor artifact root.
    const selected_policy: ?*const cc.skill_rsi.Policy = if (preview) &frozen else null;
    const artifact_root = if (preview or route == .root) root else "";
    if (!preview and route == .root) try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = cc.harnessmm.JOURNAL_NAME,
        .data = "existing journal stays untouched\n",
    });
    const expected_calls: u32 = if (preview) 2 else 1;
    switch (route) {
        .root => {
            const result = try cc.agent_loop.run(&conversation, client.provider(), defs, &permission, .{
                .preview = preview,
                .harnessmm = true,
                .rsi = true,
                .rsi_policy = selected_policy,
                .max_turns = 2,
                .cwd_abs = root,
                .home_dir = root,
                .artifact_root = artifact_root,
            }, &backend, a);
            try std.testing.expectEqual(expected_calls, result.tool_calls);
        },
        .child => {
            const result = try cc.core_subagent.spawnAgentSink(a, client.provider(), &client, defs, &permission, null, "read before editing", .{
                .preview = preview,
                .harnessmm = true,
                .rsi = true,
                .rsi_policy = selected_policy,
                .session = cc.session_id.SessionId.single,
                .agent_depth = 1,
                .max_turns = 2,
                .cwd_abs = root,
                .home_dir = root,
                .artifact_root = artifact_root,
            }, &backend);
            defer result.deinit();
            try std.testing.expectEqual(expected_calls, result.tool_calls);
        },
        .background => {
            var registry = try cc.agent_job_registry.AgentJobRegistry.init(a, "test-key", url, MODEL, .anthropic);
            defer registry.deinit();
            const id = try registry.spawnBackground(.{
                .preview = preview,
                .harnessmm = true,
                .rsi = true,
                .rsi_policy = selected_policy,
                .prompt = "",
                .system_prompt = "",
                .session = cc.session_id.SessionId.single,
                .tool_defs = defs,
                .permission_ctx = permission,
                .agent_depth = 0,
                .max_turns = 2,
                .cwd_abs = root,
                .home_dir = root,
                .artifact_root = artifact_root,
                .prebuilt_conversation = try conversation.cloneInto(a),
            });
            const entry = registry.get(id) orelse return error.MissingBackgroundJob;
            var terminal = false;
            for (0..300) |_| {
                if (entry.waitForOutputOrTerminal(null, 100 * std.time.ns_per_ms)) {
                    terminal = true;
                    break;
                }
            }
            try std.testing.expect(terminal);
            entry.lockPublic();
            const status = entry.status;
            const calls = entry.tool_calls;
            entry.unlockPublic();
            try std.testing.expectEqual(cc.agent_job_registry.JobStatus.done, status);
            try std.testing.expectEqual(expected_calls, calls);
        },
    }
    try std.testing.expectEqual(@as(usize, if (preview) 1 else 2), server.requestCount());
    const first = server.requestAt(0) orelse return error.MissingRequest;
    try std.testing.expectEqual(preview, std.mem.indexOf(u8, first.body(), cc.harnessmm.AUTHOR_MARKER) != null);
    try std.testing.expectEqual(preview, std.mem.indexOf(u8, first.body(), INSTRUCTION) != null);
    if (preview) {
        const journal = try tmp.dir.readFileAlloc(std.testing.io, cc.harnessmm.JOURNAL_NAME, a, .limited(65536));
        defer a.free(journal);
        try std.testing.expect(std.mem.indexOf(u8, journal, "\"decision_id\":\"A\"") != null);
    } else if (route == .root) {
        const journal = try tmp.dir.readFileAlloc(std.testing.io, cc.harnessmm.JOURNAL_NAME, a, .limited(65536));
        defer a.free(journal);
        try std.testing.expectEqualStrings("existing journal stays untouched\n", journal);
    } else {
        try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(std.testing.io, cc.harnessmm.JOURNAL_NAME, a, .limited(65536)));
    }
}

test "L2 HarnessMM preview: kernel opt-out skips RSI policy and certificate I/O" {
    try checkPreviewRoute(.root, false);
}

test "L2 HarnessMM preview: explicit child selections require inherited preview" {
    try checkPreviewRoute(.child, false);
    try checkPreviewRoute(.child, true);
}

test "L2 HarnessMM preview: background handoff preserves preview and explicit selections" {
    try checkPreviewRoute(.background, false);
    try checkPreviewRoute(.background, true);
}

test "L2 HarnessMM preview: resume filters inactive host notes and never replays a historical graph" {
    const a = std.testing.allocator;
    const Selection = struct { preview: bool, harnessmm: bool, rsi: bool };
    for ([_]Selection{
        .{ .preview = false, .harnessmm = true, .rsi = true },
        .{ .preview = true, .harnessmm = false, .rsi = true },
        .{ .preview = true, .harnessmm = true, .rsi = false },
        .{ .preview = true, .harnessmm = true, .rsi = true },
    }) |selection| {
        const reuse = selection.preview and selection.harnessmm;
        const rsi = selection.preview and selection.rsi;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
        var server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var io = @import("platform").signal.threadedIo(a, .{});
        defer io.deinit();
        var client = cc.client_mod.Client.initWithBaseUrl(a, io.io(), "test-key", MODEL, url);
        defer client.deinit();
        var original = cc.conversation.Conversation.init(a);
        defer original.deinit();
        try original.appendText(.user, "read before editing");
        try original.appendHostText(cc.harnessmm.AUTHOR_PROMPT);
        try original.appendHostText(cc.skill_rsi.PREFIX ++ INSTRUCTION ++ cc.skill_rsi.SUFFIX);
        var blocks = [_]cc.message.Block{
            .{ .text = PLAN },
            .{ .tool_use = .{ .id = "root_call", .name = "Bash", .input = "{\"command\":\"printf root\"}" } },
        };
        try original.append(try (cc.message.Message{ .role = .assistant, .blocks = &blocks }).dupe(a));
        var restored = try original.cloneInto(a);
        defer restored.deinit();
        var permission = cc.permission.createContext(.bypass_permissions, a);
        permission.no_interactive_prompt = true;
        const defs = try cc.tools.toToolDefinitions(a);
        defer a.free(defs);
        var render = cc.writer_backend.WriterBackend.initNull();
        const backend = render.backend();
        const hash = cc.harnessmm.sha256(INSTRUCTION);
        const frozen = policy(&hash);
        const result = try cc.agent_loop.resumeRun(&restored, client.provider(), defs, &permission, "root_call", "{\"schema_version\":\"metacodes.bash-result.v2\",\"exit_code\":0}", &.{}, .{
            .preview = selection.preview,
            .harnessmm = selection.harnessmm,
            .rsi = selection.rsi,
            .rsi_policy = if (rsi) &frozen else null,
            .max_turns = 1,
            .artifact_root = if (reuse) root else "",
        }, &backend, a);
        try std.testing.expectEqual(@as(u32, 0), result.tool_calls);
        try std.testing.expectEqual(@as(usize, 1), server.requestCount());
        const request = server.lastRequest() orelse return error.MissingRequest;
        try std.testing.expectEqual(reuse, std.mem.indexOf(u8, request.body(), cc.harnessmm.AUTHOR_MARKER) != null);
        try std.testing.expectEqual(rsi, std.mem.indexOf(u8, request.body(), INSTRUCTION) != null);
        try std.testing.expect(std.mem.indexOf(u8, request.body(), "root_call") != null);
        // Opting out changes only the wire projection, never the stored notes.
        try std.testing.expectEqualStrings(cc.harnessmm.AUTHOR_PROMPT, restored.messages.items[1].blocks[0].text);
        try std.testing.expectEqualStrings(original.messages.items[2].blocks[0].text, restored.messages.items[2].blocks[0].text);
        if (reuse) {
            const journal = try tmp.dir.readFileAlloc(std.testing.io, cc.harnessmm.JOURNAL_NAME, a, .limited(65536));
            defer a.free(journal);
            try std.testing.expectEqual(@as(usize, 0), journal.len);
        }
    }
}

test "L2 HarnessMM: fast native calls consume turns and stop before the next EDG node" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX fixture commands
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    const response = try rootResponse(a);
    defer a.free(response);
    var server = try harness.MockServer.startCassette(&.{response}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "run the bounded chain");
    var permission = cc.permission.createContext(.bypass_permissions, a);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var render = cc.writer_backend.WriterBackend.initNull();
    const backend = render.backend();
    const result = try cc.agent_loop.run(&conversation, client.provider(), defs, &permission, .{
        .preview = true,
        .harnessmm = true,
        .max_turns = 2,
        .cwd_abs = root,
        .home_dir = root,
        .artifact_root = root,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.max_turns, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), result.turns);
    try std.testing.expectEqual(@as(u32, 2), result.tool_calls);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    var receipts: usize = 0;
    var host_calls: usize = 0;
    for (conversation.messages.items) |message| for (message.blocks) |block| {
        if (block == .tool_result) receipts += 1;
        if (block == .tool_use and message.origin == .host) {
            host_calls += 1;
            try std.testing.expectEqualStrings("{\"command\":\"printf one\"}", block.tool_use.input);
        }
    };
    try std.testing.expectEqual(@as(usize, 2), receipts);
    try std.testing.expectEqual(@as(usize, 1), host_calls);
    const journal = try tmp.dir.readFileAlloc(std.testing.io, cc.harnessmm.JOURNAL_NAME, a, .limited(65536));
    defer a.free(journal);
    var certificate = try std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, journal, "\n"), .{});
    defer certificate.deinit();
    try std.testing.expectEqualStrings("A", certificate.value.object.get("decision_id").?.string);
    try std.testing.expectEqual(@as(i64, 2), certificate.value.object.get("omitted_callback_turn").?.integer);
}
