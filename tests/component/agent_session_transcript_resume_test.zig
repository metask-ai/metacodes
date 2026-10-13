//! L2: an embedding Host persists and resumes an AgentSession transcript
//! through one path definition.
//!
//! The Host writes with `transcript.Writer.init(root, stateRoot())` from the
//! live Session and, after a restart, finds the same directory with
//! `transcript.sessionDir` over a `WorkspacePolicy` resolved from the same
//! config. The restored Session must then send the earlier turn to the
//! provider. A cloud Host that spelled the layout out by hand broke silently
//! when `Writer.init`'s third parameter changed from home to state root; the
//! parameter is now a `StateRoot`, and this test pins that write side and
//! resume side agree for both a default and an explicit state root.
//!
//! Cross-module: agent_session + workspace_policy + transcript + conversation
//! + provider request assembly.

const std = @import("std");
const pfs = @import("platform").fs;
const harness = @import("harness");
const cc = @import("cc");

fn textSse(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_t\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{text});
}

const Sink = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: u64, _: cc.ui_event.CoreEvent) bool {
        return true;
    }
};

fn subdir(tmp: *std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    try tmp.dir.createDirPath(std.testing.io, name);
    var sub = try tmp.dir.openDir(std.testing.io, name, .{});
    defer sub.close(std.testing.io);
    const len = try sub.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

/// Runs one turn, persists it the way a Host does, restores the Session from
/// disk in the same Runtime and runs a second turn. Returns the transcript
/// directory the Host wrote (caller-owned).
fn persistAndResume(allocator: std.mem.Allocator, workspace: cc.workspace_policy.Config) ![]u8 {
    const first = try textSse(allocator, "pelican noted");
    defer allocator.free(first);
    const second = try textSse(allocator, "it was the pelican");
    defer allocator.free(second);
    const bodies = [_][]const u8{ first, second };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    const config: cc.agent_session.SessionConfig = .{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .workspace = workspace,
        .allowed_tools = &.{},
    };
    var sink_state: u8 = 0;

    // Live Session: the Host flushes the committed Conversation after a Run.
    var sid: cc.session_id.SessionId = undefined;
    const written_dir = blk: {
        const session = try runtime.createSession(config);
        defer session.destroy() catch unreachable;
        sid = session.session_id;
        _ = try session.runText(1, "remember the word pelican", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
        var writer = try cc.transcript.Writer.init(allocator, session.workspace.root, session.workspace.stateRoot(), "test-model", sid);
        defer writer.deinit();
        var lease = try session.snapshotCommitted();
        defer lease.deinit();
        writer.flush(lease.conversation);
        break :blk try allocator.dupe(u8, writer.dir);
    };
    errdefer allocator.free(written_dir);

    // Restart: the Session is gone. Resolve the same config again and derive
    // the directory instead of spelling the layout out.
    var policy = try cc.workspace_policy.WorkspacePolicy.init(allocator, workspace);
    defer policy.deinit();
    const resume_dir = try cc.transcript.sessionDir(allocator, policy.stateRoot(), policy.root, sid);
    defer allocator.free(resume_dir);
    try std.testing.expectEqualStrings(written_dir, resume_dir);

    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try cc.transcript.loadTranscript(&conversation, resume_dir, allocator);
    try std.testing.expectEqual(@as(usize, 2), conversation.len());

    const restored = try runtime.createRestoredSession(config, .{
        .session_id = sid,
        .last_run_id = 1,
        .last_compact_id = 0,
        .conversation = &conversation,
    });
    defer restored.destroy() catch unreachable;
    const result = try restored.runText(2, "which word was it?", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    // The provider saw the turn that only the transcript carried across.
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "remember the word pelican") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "pelican noted") != null);
    return written_dir;
}

fn isUnder(path: []const u8, root: []const u8) bool {
    return std.mem.startsWith(u8, path, root) and path.len > root.len and
        (path[root.len] == '/' or path[root.len] == '\\');
}

test "L2 AgentSession Host resumes its transcript under the default state root <home>/.metacodes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &workspace_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);

    const dir = try persistAndResume(a, .{ .root = workspace, .home = home });
    defer a.free(dir);
    // Hosts that name no state root keep the layout they always had.
    const legacy = try cc.util_state_root.legacyDefault(a, home);
    defer a.free(legacy);
    try std.testing.expect(isUnder(dir, legacy));
}

test "L2 AgentSession Host resumes its transcript under an explicit state root, not under home" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &workspace_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);
    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state = try subdir(&tmp, "tenant-state", &state_buf);

    const dir = try persistAndResume(a, .{ .root = workspace, .home = home, .state_root = state });
    defer a.free(dir);
    try std.testing.expect(isUnder(dir, state));
    try std.testing.expect(!isUnder(dir, home));
}
