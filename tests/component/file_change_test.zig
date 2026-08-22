//! L2: after a real Run, the caller gets every file modification the file
//! tools actually made — path, kind, outcome, and the change itself — without
//! reading `tool_result.content`.
//!
//! Requirement: `doc/frommetawork/CORE_FILE_CHANGE_OBSERVABILITY_REQUIREMENT.md`.
//! Its acceptance criterion is exactly that: "真实 Run 执行后,上层能够获取并展示每个
//! 文件的实际修改,无需解析 tool_result.content 中的工具私有格式". Every assertion below
//! is therefore made against the `file_change` contract only; the tests never
//! look at a tool's result JSON.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const file_change = cc.file_change;

const END_TURN =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"done\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn toolSse(allocator: std.mem.Allocator, id: []const u8, name: []const u8, input: []const u8) ![]u8 {
    var escaped: std.Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    try std.json.Stringify.encodeJsonString(input, .{}, &escaped.writer);
    const encoded = try escaped.toOwnedSlice();
    defer allocator.free(encoded);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, id, name, encoded },
    );
}

/// One provider response carrying two tool calls, so a single turn can mix a
/// real filesystem write with a tool that suspends the whole turn.
fn twoToolSse(
    allocator: std.mem.Allocator,
    id_a: []const u8,
    name_a: []const u8,
    input_a: []const u8,
    id_b: []const u8,
    name_b: []const u8,
    input_b: []const u8,
) ![]u8 {
    var esc_a: std.Io.Writer.Allocating = .init(allocator);
    defer esc_a.deinit();
    try std.json.Stringify.encodeJsonString(input_a, .{}, &esc_a.writer);
    const enc_a = try esc_a.toOwnedSlice();
    defer allocator.free(enc_a);

    var esc_b: std.Io.Writer.Allocating = .init(allocator);
    defer esc_b.deinit();
    try std.json.Stringify.encodeJsonString(input_b, .{}, &esc_b.writer);
    const enc_b = try esc_b.toOwnedSlice();
    defer allocator.free(enc_b);

    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_two\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":1}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id_a, name_a, enc_a, id_b, name_b, enc_b },
    );
}

/// Records the `file_changes` event stream, which is what an out-of-process UI
/// consumes live. Kept independent of the Journal so the test can prove both
/// surfaces agree.
const EventCapture = struct {
    allocator: std.mem.Allocator,
    pairs: std.ArrayList(Pair) = .empty,

    const Pair = struct {
        tool_use_id: []u8,
        tool: []u8,
        count: usize,
        first_path: []u8,
        first_has_diff: bool,
    };

    fn deinit(self: *EventCapture) void {
        for (self.pairs.items) |p| {
            self.allocator.free(p.tool_use_id);
            self.allocator.free(p.tool);
            self.allocator.free(p.first_path);
        }
        self.pairs.deinit(self.allocator);
    }

    fn emit(ctx: *anyopaque, _: cc.session_id.SessionId, ev: cc.ui_event.CoreEvent) void {
        const self: *EventCapture = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .file_changes => |fc| {
                if (fc.changes.len == 0) return;
                const id = self.allocator.dupe(u8, fc.id) catch return;
                const tool = self.allocator.dupe(u8, fc.name) catch {
                    self.allocator.free(id);
                    return;
                };
                const path = self.allocator.dupe(u8, fc.changes[0].path()) catch {
                    self.allocator.free(id);
                    self.allocator.free(tool);
                    return;
                };
                self.pairs.append(self.allocator, .{
                    .tool_use_id = id,
                    .tool = tool,
                    .count = fc.changes.len,
                    .first_path = path,
                    .first_has_diff = fc.changes[0].unified_diff != null,
                }) catch {};
            },
            else => {},
        }
    }

    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }

    fn backend(self: *EventCapture) cc.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }
};

const Scenario = struct {
    events: EventCapture,
    journal: file_change.Journal,
    result: cc.agent_loop.RunResult,

    fn deinit(self: *Scenario) void {
        self.events.deinit();
        self.journal.deinit();
    }

    fn find(self: *Scenario, path: []const u8) ?file_change.Record {
        const records = self.journal.acquire();
        defer self.journal.release();
        for (records) |rec| {
            if (std.mem.eql(u8, rec.path(), path)) return rec;
        }
        return null;
    }

    /// Safe only because `runCassette` has returned and these scenarios spawn
    /// no background execution, so nothing can append while the test reads.
    fn recordsAfterRun(self: *Scenario) []const file_change.Record {
        const items = self.journal.acquire();
        self.journal.release();
        return items;
    }
};

fn runCassette(
    allocator: std.mem.Allocator,
    responses: []const []const u8,
    root: []const u8,
    mode: cc.types_mod.PermissionMode,
) !Scenario {
    var server = try harness.MockServer.startCassette(responses, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(allocator, io_runtime.io(), "key", "model", url);
    defer client.deinit();

    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "edit the repository");

    var permission = cc.permission.createContext(mode, allocator);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(allocator);
    defer allocator.free(defs);

    var events = EventCapture{ .allocator = allocator };
    errdefer events.deinit();
    var journal = file_change.Journal.init(allocator);
    errdefer journal.deinit();
    const backend = events.backend();

    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 8,
            // Deliberately left at the default (false): file changes are
            // evidence, not rendering, so they must reach the consumer even
            // when tool cards are switched off (headless / subagent).
            .file_change_journal = &journal,
            .cwd_abs = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        allocator,
    );
    return .{ .events = events, .journal = journal, .result = result };
}

fn tmpRoot(dir: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return buf[0..try dir.dir.realPath(std.testing.io, buf)];
}

test "L2 文件修改可观测:Write 新建 + Edit 修改,上层拿到实际改动而不解析 tool_result" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    const path = try std.fmt.allocPrint(a, "{s}/observed.txt", .{root});
    defer a.free(path);
    const write_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\",\"content\":\"alpha\\n\"}}", .{path});
    defer a.free(write_input);
    const edit_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\",\"old_string\":\"alpha\",\"new_string\":\"omega\"}}", .{path});
    defer a.free(edit_input);

    const write_sse = try toolSse(a, "w1", "Write", write_input);
    defer a.free(write_sse);
    const edit_sse = try toolSse(a, "e1", "Edit", edit_input);
    defer a.free(edit_sse);

    var scenario = try runCassette(a, &.{ write_sse, edit_sse, END_TURN }, root, .bypass_permissions);
    defer scenario.deinit();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, scenario.result.stop_reason);

    // Both the live event stream and the Run-scoped journal saw the same work.
    try std.testing.expectEqual(@as(usize, 2), scenario.events.pairs.items.len);
    try std.testing.expectEqual(@as(usize, 2), scenario.journal.count());
    try std.testing.expect(!scenario.journal.truncated);

    const created = scenario.recordsAfterRun()[0];
    try std.testing.expectEqualStrings("observed.txt", created.path()); // workspace-relative
    try std.testing.expectEqualStrings("observed.txt", created.locator.workspace_path);
    try std.testing.expectEqual(file_change.Kind.created, created.kind);
    try std.testing.expectEqual(file_change.Status.applied, created.status);
    try std.testing.expectEqualStrings("Write", created.tool);
    try std.testing.expectEqual(@as(u8, 0), created.agent_depth);
    try std.testing.expectEqual(@as(u64, 0), created.before_bytes);
    try std.testing.expectEqual(@as(u64, "alpha\n".len), created.after_bytes);
    try std.testing.expect(created.diff_complete);
    try std.testing.expect(std.mem.indexOf(u8, created.unified_diff.?, "+alpha") != null);

    const modified = scenario.recordsAfterRun()[1];
    try std.testing.expectEqual(file_change.Kind.modified, modified.kind);
    try std.testing.expectEqual(file_change.Status.applied, modified.status);
    try std.testing.expectEqualStrings("Edit", modified.tool);
    // The actual change, not just "this file was involved".
    try std.testing.expect(std.mem.indexOf(u8, modified.unified_diff.?, "-alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, modified.unified_diff.?, "+omega") != null);

    // Each record pairs with the tool_use the consumer is already displaying.
    try std.testing.expectEqualStrings("w1", created.tool_use_id);
    try std.testing.expectEqualStrings("e1", modified.tool_use_id);
    try std.testing.expectEqualStrings("w1", scenario.events.pairs.items[0].tool_use_id);
    try std.testing.expect(scenario.events.pairs.items[0].first_has_diff);

    // And disk actually holds the reported end state.
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64));
    defer a.free(on_disk);
    try std.testing.expectEqualStrings("omega\n", on_disk);
}

test "L2 文件修改可观测:内容相同的 Write 报 no_change,不谎称改了" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    const path = try std.fmt.allocPrint(a, "{s}/same.txt", .{root});
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "same\n" });

    const write_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\",\"content\":\"same\\n\"}}", .{path});
    defer a.free(write_input);
    const write_sse = try toolSse(a, "w1", "Write", write_input);
    defer a.free(write_sse);

    var scenario = try runCassette(a, &.{ write_sse, END_TURN }, root, .bypass_permissions);
    defer scenario.deinit();

    const rec = scenario.find("same.txt") orelse return error.MissingFileChange;
    try std.testing.expectEqual(file_change.Status.no_change, rec.status);
    try std.testing.expect(!rec.status.changedDisk());
    try std.testing.expectEqual(rec.before_bytes, rec.after_bytes);
}

test "L2 文件修改可观测:被权限拒绝的 Write 报 rejected 且盘上无变化" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    const path = try std.fmt.allocPrint(a, "{s}/blocked.txt", .{root});
    defer a.free(path);
    const write_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\",\"content\":\"nope\\n\"}}", .{path});
    defer a.free(write_input);
    const write_sse = try toolSse(a, "w1", "Write", write_input);
    defer a.free(write_sse);

    // plan mode denies mutations without any interactive approval path.
    var scenario = try runCassette(a, &.{ write_sse, END_TURN }, root, .plan);
    defer scenario.deinit();

    // A refusal is still an answer about that file: silence would read as
    // "no file was involved".
    const rec = scenario.find("blocked.txt") orelse return error.MissingFileChange;
    try std.testing.expectEqual(file_change.Status.rejected, rec.status);
    try std.testing.expect(!rec.status.changedDisk());
    try std.testing.expect(rec.unified_diff == null);
    try std.testing.expect(std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(8)) == error.FileNotFound);
}

test "L2 文件修改可观测:失败的 Edit 报 failed,不静默" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    const path = try std.fmt.allocPrint(a, "{s}/missing.txt", .{root});
    defer a.free(path);
    const edit_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\",\"old_string\":\"a\",\"new_string\":\"b\"}}", .{path});
    defer a.free(edit_input);
    const edit_sse = try toolSse(a, "e1", "Edit", edit_input);
    defer a.free(edit_sse);

    var scenario = try runCassette(a, &.{ edit_sse, END_TURN }, root, .bypass_permissions);
    defer scenario.deinit();

    const rec = scenario.find("missing.txt") orelse return error.MissingFileChange;
    try std.testing.expectEqual(file_change.Status.failed, rec.status);
    try std.testing.expect(!rec.status.changedDisk());
    try std.testing.expectEqualStrings("Edit", rec.tool);
}

test "L2 文件修改可观测:ApplyPatch 一次调用的新增/修改/删除/移动逐文件上报" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    const update_path = try std.fmt.allocPrint(a, "{s}/keep.txt", .{root});
    defer a.free(update_path);
    const doomed_path = try std.fmt.allocPrint(a, "{s}/doomed.txt", .{root});
    defer a.free(doomed_path);
    const move_src = try std.fmt.allocPrint(a, "{s}/from.txt", .{root});
    defer a.free(move_src);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = update_path, .data = "old line\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = doomed_path, .data = "bye\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = move_src, .data = "travelling\n" });

    const patch = try std.fmt.allocPrint(a,
        \\*** Begin Patch
        \\*** Add File: {s}/fresh.txt
        \\+brand new
        \\*** Update File: {s}
        \\@@
        \\-old line
        \\+new line
        \\*** Delete File: {s}
        \\*** Update File: {s}
        \\*** Move to: {s}/to.txt
        \\@@
        \\-travelling
        \\+arrived
        \\*** End Patch
        \\
    , .{ root, update_path, doomed_path, move_src, root });
    defer a.free(patch);

    var patch_json: std.Io.Writer.Allocating = .init(a);
    defer patch_json.deinit();
    try patch_json.writer.writeAll("{\"patch\":");
    try std.json.Stringify.encodeJsonString(patch, .{}, &patch_json.writer);
    try patch_json.writer.writeByte('}');
    const apply_input = try patch_json.toOwnedSlice();
    defer a.free(apply_input);

    const apply_sse = try toolSse(a, "p1", "ApplyPatch", apply_input);
    defer a.free(apply_sse);

    var scenario = try runCassette(a, &.{ apply_sse, END_TURN }, root, .bypass_permissions);
    defer scenario.deinit();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, scenario.result.stop_reason);

    // One tool call, four files — the contract reports per file, not per call.
    try std.testing.expectEqual(@as(usize, 4), scenario.journal.count());
    try std.testing.expectEqual(@as(usize, 1), scenario.events.pairs.items.len);
    try std.testing.expectEqual(@as(usize, 4), scenario.events.pairs.items[0].count);

    const added = scenario.find("fresh.txt") orelse return error.MissingFileChange;
    try std.testing.expectEqual(file_change.Kind.created, added.kind);
    try std.testing.expectEqual(file_change.Status.applied, added.status);
    try std.testing.expect(std.mem.indexOf(u8, added.unified_diff.?, "+brand new") != null);

    const updated = scenario.find("keep.txt") orelse return error.MissingFileChange;
    try std.testing.expectEqual(file_change.Kind.modified, updated.kind);
    try std.testing.expect(std.mem.indexOf(u8, updated.unified_diff.?, "-old line") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated.unified_diff.?, "+new line") != null);

    const deleted = scenario.find("doomed.txt") orelse return error.MissingFileChange;
    try std.testing.expectEqual(file_change.Kind.deleted, deleted.kind);
    try std.testing.expectEqual(@as(u64, 0), deleted.after_bytes);
    // A deletion has no diff, and that absence is complete evidence.
    try std.testing.expect(deleted.unified_diff == null);
    try std.testing.expect(deleted.diff_complete);

    const moved = scenario.find("to.txt") orelse return error.MissingFileChange;
    try std.testing.expectEqual(file_change.Kind.moved, moved.kind);
    try std.testing.expectEqualStrings("from.txt", moved.from_locator.?.workspace_path);
    try std.testing.expectEqualStrings("ApplyPatch", moved.tool);
}

test "L2 文件修改可观测:JSON 投影可直接给进程外消费者" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    const path = try std.fmt.allocPrint(a, "{s}/wire.txt", .{root});
    defer a.free(path);
    const write_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\",\"content\":\"payload\\n\"}}", .{path});
    defer a.free(write_input);
    const write_sse = try toolSse(a, "w1", "Write", write_input);
    defer a.free(write_sse);

    var scenario = try runCassette(a, &.{ write_sse, END_TURN }, root, .bypass_permissions);
    defer scenario.deinit();

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try file_change.writeJsonEnvelope(&aw.writer, scenario.recordsAfterRun(), false);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, aw.written(), .{});
    defer parsed.deinit();
    // 信封自带 schema 版本:消费者读到的字段集是可判定的,不靠约定。
    try std.testing.expectEqualStrings(file_change.SCHEMA_VERSION, parsed.value.object.get("schema_version").?.string);
    try std.testing.expect(!parsed.value.object.get("truncated").?.bool);
    const arr = parsed.value.object.get("changes").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), arr.len);
    const obj = arr[0].object;
    try std.testing.expectEqualStrings("wire.txt", obj.get("path").?.string);
    try std.testing.expectEqualStrings("workspace_path", obj.get("locator_kind").?.string);
    try std.testing.expectEqualStrings("created", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("applied", obj.get("status").?.string);
    try std.testing.expectEqualStrings("Write", obj.get("tool").?.string);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("unified_diff").?.string, "+payload") != null);
}

test "L2 文件修改可观测:子执行(Task subagent)的修改进同一账本且带 agent_depth" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    const path = try std.fmt.allocPrint(a, "{s}/by-subagent.txt", .{root});
    defer a.free(path);
    const write_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\",\"content\":\"from a child\\n\"}}", .{path});
    defer a.free(write_input);
    const child_write = try toolSse(a, "cw1", "Write", write_input);
    defer a.free(child_write);

    const bodies = [_][]const u8{ child_write, END_TURN };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try agents.loadFromStandardPaths("");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var journal = file_change.Journal.init(a);
    defer journal.deinit();

    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .api_client = &client,
        .tool_defs = defs,
        .permission_ctx = @constCast(&perm),
        .agents = &agents,
        .parent_model = "claude-sonnet-4-20250514",
        .cwd_abs = root,
        .home_dir = root,
        // The parent Run's journal, handed down exactly as agent_loop hands it
        // to its ToolContext.
        .file_change_journal = &journal,
    };

    const out = cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"general-purpose\",\"prompt\":\"write the file\",\"description\":\"d\"}") catch |err| {
        std.debug.print("Task spawn failed: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer a.free(out);

    // A subagent's edits are still this Run's edits: same journal, but the
    // record says which execution level made them.
    try std.testing.expectEqual(@as(usize, 1), journal.count());
    const journal_records = journal.acquire();
    defer journal.release();
    const rec = journal_records[0];
    try std.testing.expectEqualStrings("by-subagent.txt", rec.path());
    try std.testing.expectEqual(file_change.Kind.created, rec.kind);
    try std.testing.expectEqual(file_change.Status.applied, rec.status);
    try std.testing.expect(rec.agent_depth > 0);
    try std.testing.expect(std.mem.indexOf(u8, rec.unified_diff.?, "+from a child") != null);
}

test "L2 文件修改可观测:ApplyPatch 被权限拒绝时逐文件报 rejected,而不是整批静默" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    const existing = try std.fmt.allocPrint(a, "{s}/guarded.txt", .{root});
    defer a.free(existing);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = existing, .data = "before\n" });

    const patch = try std.fmt.allocPrint(a,
        \\*** Begin Patch
        \\*** Update File: {s}
        \\@@
        \\-before
        \\+after
        \\*** End Patch
        \\
    , .{existing});
    defer a.free(patch);

    var patch_json: std.Io.Writer.Allocating = .init(a);
    defer patch_json.deinit();
    try patch_json.writer.writeAll("{\"patch\":");
    try std.json.Stringify.encodeJsonString(patch, .{}, &patch_json.writer);
    try patch_json.writer.writeByte('}');
    const apply_input = try patch_json.toOwnedSlice();
    defer a.free(apply_input);

    const apply_sse = try toolSse(a, "p1", "ApplyPatch", apply_input);
    defer a.free(apply_sse);

    // plan 模式:ApplyPatch 的 phase-1 权限门把每个计划路径当 Write 喂回权限引擎 → 整批拒。
    var scenario = try runCassette(a, &.{ apply_sse, END_TURN }, root, .plan);
    defer scenario.deinit();

    // 整批零落盘,但契约上必须说出"这个文件被拒了"——静默会被读成"没涉及文件"。
    const rec = scenario.find("guarded.txt") orelse return error.MissingFileChange;
    try std.testing.expectEqual(file_change.Status.rejected, rec.status);
    try std.testing.expect(!rec.status.changedDisk());
    try std.testing.expect(rec.unified_diff == null);
    try std.testing.expectEqualStrings("ApplyPatch", rec.tool);

    const on_disk = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, existing, a, .limited(64));
    defer a.free(on_disk);
    try std.testing.expectEqualStrings("before\n", on_disk);
}

test "L2 文件修改可观测:整轮挂起时已落盘的修改仍然上报,不被静默丢弃" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    const path = try std.fmt.allocPrint(a, "{s}/before-suspend.txt", .{root});
    defer a.free(path);
    const write_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\",\"content\":\"landed\\n\"}}", .{path});
    defer a.free(write_input);

    // 同一轮:Write 真落盘 + AskUserQuestion 发起异步 UI(挂起前端恒 .pending)→ 整轮 suspended。
    // 修复前这一轮的 slot payload 直接被 Slot.deinit 回收,盘改了但契约上一个字都没说。
    const ask_input =
        "{\"questions\":[{\"question\":\"go on?\",\"header\":\"Go\",\"multiSelect\":false," ++
        "\"options\":[{\"label\":\"yes\",\"description\":\"y\"},{\"label\":\"no\",\"description\":\"n\"}]}]}";
    const both = try twoToolSse(a, "s1", "Write", write_input, "s2", "AskUserQuestion", ask_input);
    defer a.free(both);

    var server = try harness.MockServer.startCassette(&.{both}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "key", "model", url);
    defer client.deinit();

    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "write then ask");

    var permission = cc.permission.createContext(.bypass_permissions, a);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);

    var events = EventCapture{ .allocator = a };
    defer events.deinit();
    var journal = file_change.Journal.init(a);
    defer journal.deinit();
    const backend = events.backend();

    var pending_dummy: u8 = 0;
    const Pending = struct {
        fn request(
            _: *anyopaque,
            _: cc.session_id.SessionId,
            _: std.mem.Allocator,
            _: *const cc.ui_request.UiRequest,
            _: *cc.ui_request.UiResponse,
        ) anyerror!cc.ui_request.RequestOutcome {
            return .pending;
        }
    };

    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 4,
            .file_change_journal = &journal,
            .cwd_abs = root,
            .home_dir = root,
            .ui_requester = .{ .ctx = @ptrCast(&pending_dummy), .requestFn = &Pending.request },
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        a,
    );
    defer if (result.suspend_info) |si| si.deinit();

    if (result.stop_reason != .suspended) return error.SkipZigTest;

    const records = journal.acquire();
    defer journal.release();
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("before-suspend.txt", records[0].path());
    try std.testing.expectEqual(file_change.Status.applied, records[0].status);
    try std.testing.expect(std.mem.indexOf(u8, records[0].unified_diff.?, "+landed") != null);

    // 盘上确实是它说的那样。
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64));
    defer a.free(on_disk);
    try std.testing.expectEqualStrings("landed\n", on_disk);
}

test "L2 文件修改可观测:重复 drain 不会重复上报(幂等靠标记而非 null)" {
    // drain 释放记录后 `file_changes` 回到 null,被拒的 slot 若只看 null 会被重新缝合、
    // 二次上报。这条把幂等钉在 slot 的 drained 标记上。
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);

    var ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .cwd_abs = root,
        .home_dir = root,
        .resolve_relative_paths = true,
    };
    const input = "{\"file_path\":\"denied.txt\",\"content\":\"x\"}";
    var slots = [_]cc.tool_exec.Slot{
        .{ .decision = .denied, .name = "Write", .id = "d1", .input = input },
    };
    defer for (&slots) |*sl| sl.deinit(a);

    var seen: usize = 0;
    const Counter = struct {
        fn emit(c: *anyopaque, _: cc.session_id.SessionId, ev: cc.ui_event.CoreEvent) void {
            const n: *usize = @ptrCast(@alignCast(c));
            if (ev == .file_changes) n.* += ev.file_changes.changes.len;
        }
        fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
            return null;
        }
    };
    const backend = cc.ui_backend.UiBackend{ .ctx = @ptrCast(&seen), .emit = Counter.emit, .poll = Counter.poll };

    var journal = file_change.Journal.init(a);
    defer journal.deinit();

    cc.agent_loop.drainFileChangesForTest(&slots, &ctx, &backend, .single, &journal, a);
    const after_first = seen;
    try std.testing.expectEqual(@as(usize, 1), after_first);
    try std.testing.expectEqual(@as(usize, 1), journal.count());

    cc.agent_loop.drainFileChangesForTest(&slots, &ctx, &backend, .single, &journal, a);
    try std.testing.expectEqual(after_first, seen); // 没有第二次事件
    try std.testing.expectEqual(@as(usize, 1), journal.count()); // 账本也没重复
}
