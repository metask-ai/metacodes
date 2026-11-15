//! L2 regression for #494: the permission check and the executor read one
//! spelling of a tool call's arguments.
//!
//! Defect 1: arguments naming a key twice (`"-i"` twice in a Grep call,
//! `file_path` twice in a Read call) failed the permission layer's strict
//! parse, and that failure became a deny. The model got `permission_denied`
//! (category safety, not recoverable) for an argument mistake it could fix.
//! Defect 2: Grep found its `path` by the substring `"path":`, so
//! `"path" : "target.ts"` fell back to the working directory while the
//! permission layer, parsing the JSON, judged `target.ts`.
//!
//! Fix: the agent loop admits a call's arguments before the hook, the
//! permission check and the dispatch see them (`tools/common.canonicalizeArgs`):
//! one JSON object with no duplicate key, in one canonical spelling, or a
//! recoverable `invalid_args`. Executors read top-level members structurally
//! (`extractJsonArg` / `util/json.topLevel*Field`).
//!
//! Crosses agent_loop → argument admission → permission decision → tools
//! dispatch → Grep → the repository-pinned ripgrep. Y is the tool result the
//! provider receives on the next request: an `invalid_args` error, or the
//! lines a search of exactly `target.ts` returns.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_end\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const NullBackend = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: cc.ui_event.CoreEvent) void {}
    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
    fn backend(self: *NullBackend) cc.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }
};

const Call = struct { id: []const u8, name: []const u8, args: []const u8 };

/// One assistant turn streaming each call's arguments verbatim as
/// `partial_json`: the bytes reach the loop exactly as a model spelled them.
fn toolTurnSse(a: std.mem.Allocator, calls: []const Call) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_494\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n");
    for (calls, 0..) |call, index| {
        try w.print("data: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n", .{ index, call.id, call.name });
        try w.print("data: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{f}}}}}\n\n", .{ index, std.json.fmt(call.args, .{}) });
        try w.print("data: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{index});
    }
    try w.writeAll("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n");
    try w.writeAll("data: {\"type\":\"message_stop\"}\n\n");
    return out.toOwnedSlice();
}

/// The tool_result text the provider received for `tool_use_id` (owned).
fn toolResult(a: std.mem.Allocator, request_body: []const u8, tool_use_id: []const u8) ![]u8 {
    // The request replays the model's tool_use input verbatim, duplicates included.
    var parsed = try std.json.parseFromSlice(std.json.Value, a, request_body, .{ .duplicate_field_behavior = .use_last });
    defer parsed.deinit();
    for (parsed.value.object.get("messages").?.array.items) |message| {
        const content = message.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |block| {
            const kind = block.object.get("type") orelse continue;
            if (kind != .string or !std.mem.eql(u8, kind.string, "tool_result")) continue;
            if (!std.mem.eql(u8, block.object.get("tool_use_id").?.string, tool_use_id)) continue;
            switch (block.object.get("content").?) {
                .string => |text| return a.dupe(u8, text),
                .array => |parts| {
                    var text: std.ArrayList(u8) = .empty;
                    errdefer text.deinit(a);
                    for (parts.items) |part| if (part.object.get("text")) |t| try text.appendSlice(a, t.string);
                    return text.toOwnedSlice(a);
                },
                else => return error.UnexpectedToolResultShape,
            }
        }
    }
    return error.MissingToolResult;
}

fn expectInvalidArgs(a: std.mem.Allocator, result_text: []const u8) !void {
    errdefer std.debug.print("tool result: {s}\n", .{result_text});
    var parsed = try std.json.parseFromSlice(std.json.Value, a, result_text, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("invalid_args", err.get("code").?.string);
    try std.testing.expectEqualStrings("user_error", err.get("category").?.string);
    try std.testing.expect(err.get("recoverable").?.bool);
}

/// The repository-pinned ripgrep (#460 wiring), digest-checked.
fn usePinnedRipgrep(path_buf: *[std.fs.max_path_bytes:0]u8) !bool {
    const raw = std.c.getenv("METACODES_TEST_PINNED_RG") orelse return error.PinnedRipgrepNotWired;
    const path = std.mem.span(raw);
    if (std.mem.eql(u8, path, "unavailable")) return false;
    const want = std.mem.span(std.c.getenv("METACODES_TEST_PINNED_RG_SHA256") orelse return error.PinnedRipgrepNotWired);
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z = path_buf[0..path.len :0];
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return error.PinnedRipgrepMissing;
    defer pfs.close(fd);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &chunk);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        hasher.update(chunk[0..@intCast(n)]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const got = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(want, &got);
    cc.util_toolchain.test_ripgrep_path_override = path_z;
    return true;
}

/// Runs one tool turn through the CLI agent loop with `mode`, the workspace
/// `root` as the tools' working directory, and returns the follow-up request
/// body (owned) that carries the tool results.
fn runTurn(a: std.mem.Allocator, mode: cc.types_mod.PermissionMode, root: []const u8, calls: []const Call) ![]u8 {
    const tool_sse = try toolTurnSse(a, calls);
    defer a.free(tool_sse);
    const responses = [_][]const u8{ tool_sse, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&responses, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "search the target");
    var permission = cc.permission.createContext(mode, a);
    permission.no_interactive_prompt = true;
    var null_backend = NullBackend{};
    const backend = null_backend.backend();
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        &.{},
        &permission,
        .{ .max_turns = 2, .cwd_abs = root, .resolve_relative_paths = true },
        &backend,
        a,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    return a.dupe(u8, (server.requestAt(1) orelse return error.MissingFollowUpRequest).body());
}

test "L2 #494: duplicate argument keys are a recoverable invalid_args in every permission mode, never a deny" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.ts", .data = "const needle = 1;\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "decoy.ts", .data = "const decoy_needle = 2;\n" });

    const calls = [_]Call{
        .{ .id = "tu_grep", .name = "Grep", .args = "{\"output_mode\":\"content\",\"path\":\"target.ts\",\"pattern\":\"needle\",\"-i\":true,\"-n\":true,\"glob\":\"*.ts\",\"-i\":true,\"-n\":true}" },
        .{ .id = "tu_read", .name = "Read", .args = "{\"file_path\":\"target.ts\",\"file_path\":\"decoy.ts\"}" },
        .{ .id = "tu_nested", .name = "Grep", .args = "{\"pattern\":\"needle\",\"o\":{\"k\":1,\"k\":2}}" },
    };
    for ([_]cc.types_mod.PermissionMode{ .default, .bypass_permissions, .dont_ask }) |mode| {
        errdefer std.debug.print("mode={s}\n", .{@tagName(mode)});
        const body = try runTurn(a, mode, root, &calls);
        defer a.free(body);
        for (calls) |call| {
            errdefer std.debug.print("call={s}\n", .{call.id});
            const text = try toolResult(a, body, call.id);
            defer a.free(text);
            try std.testing.expect(std.mem.indexOf(u8, text, "permission_denied") == null);
            try expectInvalidArgs(a, text);
        }
        try std.testing.expect(std.mem.indexOf(u8, body, "decoy_needle") == null);
    }
}

test "L2 #494: whitespace before the colon names the same Grep path the permission check judged" {
    var rg_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (!try usePinnedRipgrep(&rg_buf)) return error.SkipZigTest;
    defer cc.util_toolchain.test_ripgrep_path_override = null;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.ts", .data = "const needle_in_target = 1;\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "decoy.ts", .data = "const needle_in_decoy = 2;\n" });

    const body = try runTurn(a, .default, root, &.{
        .{ .id = "tu_compact", .name = "Grep", .args = "{\"pattern\":\"needle\",\"path\":\"target.ts\",\"output_mode\":\"content\"}" },
        .{ .id = "tu_spaced", .name = "Grep", .args = "{\"pattern\":\"needle\",\"path\" : \"target.ts\",\"output_mode\":\"content\"}" },
        .{ .id = "tu_pretty", .name = "Grep", .args = "{\n  \"pattern\" :\t\"needle\",\n  \"path\"\n :  \"target.ts\" ,\n  \"output_mode\" : \"content\"\n}" },
    });
    defer a.free(body);
    const compact = try toolResult(a, body, "tu_compact");
    defer a.free(compact);
    errdefer std.debug.print("compact: {s}\n", .{compact});
    try std.testing.expect(std.mem.indexOf(u8, compact, "needle_in_target") != null);
    try std.testing.expect(std.mem.indexOf(u8, compact, "needle_in_decoy") == null);
    // Before #494 the spaced spellings searched the whole working directory
    // and returned the decoy line too.
    for ([_][]const u8{ "tu_spaced", "tu_pretty" }) |id| {
        const text = try toolResult(a, body, id);
        defer a.free(text);
        errdefer std.debug.print("{s}: {s}\n", .{ id, text });
        try std.testing.expectEqualStrings(compact, text);
    }
}
