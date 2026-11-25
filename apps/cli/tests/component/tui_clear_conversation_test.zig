//! L2 component test: `/clear` (App.clearConversation) on a real App.
//!
//! Claude Code's `/clear` starts a new session with empty context; the old
//! one stays on disk. The TUI used to advertise that and only clear the
//! screen. Asserted here end to end on the App the REPL drives:
//!   - the conversation is empty and the session id is new;
//!   - the old session stays in the agent scope (its background work stays
//!     visible and stoppable, as after a Ctrl+B hand-off);
//!   - what the model read or changed in the old conversation no longer
//!     counts (must-read-first table, file-change journal).

const std = @import("std");
const cc = @import("cc");
const ppaths = @import("platform").paths;

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: [*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
        return .{ .allocator = allocator, .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            self.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
        self.* = undefined;
    }
};

test "/clear: a new session with empty context; the old one stays in scope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root_buffer);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const home_z = try allocator.dupeZ(u8, root_buffer[0..len]);
    var home_guard = try EnvGuard.set(std.testing.allocator, "HOME", home_z.ptr);
    defer home_guard.restore();
    var probe_guard = try EnvGuard.set(std.testing.allocator, "METACODES_NO_PROBE", "1");
    defer probe_guard.restore();
    var kg_guard = try EnvGuard.set(std.testing.allocator, "METACODES_KG_AUTOSTART", "0");
    defer kg_guard.restore();

    const argv = [_][*:0]const u8{ "metacodes", "--permission", "bypassPermissions" };
    const config = cc.parseArgsForTest(&argv, allocator);
    try std.testing.expect(config.parse_error == null);
    var io_rt = @import("platform").signal.threadedIo(allocator, .{});
    defer io_rt.deinit();
    const app = try cc.app_module.App.init(allocator, io_rt.io(), config, "test-key");
    defer app.deinit();

    try app.conversation.appendText(.user, "remember the number 42");
    try app.conversation.appendText(.assistant, "noted");
    try app.read_state.record("/tmp/clear-test-file.txt", 1, 3);
    app.file_change_journal.noteTruncated();
    var old_id_buf: [64]u8 = undefined;
    const old_id = try std.fmt.bufPrint(&old_id_buf, "{s}", .{app.session_id.asSlice()});

    app.clearConversation();

    try std.testing.expectEqual(@as(usize, 0), app.conversation.len());
    try std.testing.expect(!std.mem.eql(u8, old_id, app.session_id.asSlice()));
    // The permission router and the swarm follow the new session.
    try std.testing.expect(std.mem.eql(u8, app.session_id.asSlice(), app.permission_ctx.session.asSlice()));
    // The old session is still in the agent scope.
    const scope = app.agentJobScope();
    var kept = false;
    for (scope.handed_off) |id| kept = kept or std.mem.eql(u8, id.asSlice(), old_id);
    try std.testing.expect(kept);
    // Nothing the model saw before counts now.
    try std.testing.expect(app.read_state.get("/tmp/clear-test-file.txt") == null);
    try std.testing.expectEqual(@as(usize, 0), app.file_change_journal.count());
    try std.testing.expect(!app.file_change_journal.truncated);

    // A second /clear works the same way (no capacity is left reserved).
    try app.conversation.appendText(.user, "again");
    app.clearConversation();
    try std.testing.expectEqual(@as(usize, 0), app.conversation.len());
}
