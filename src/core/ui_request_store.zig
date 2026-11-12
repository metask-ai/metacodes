//! What a SessionHost keeps about a Session's UI requests in the Session's
//! directory (#446), as `ui_requests.json`:
//!
//! - the id the next request takes, so a Session never reuses an id across
//!   restarts and a late answer to a request of an earlier process cannot
//!   reach a newer request;
//! - the request a suspended Run waits for (`SessionHost.Options.
//!   ui_request_wait = .suspend`), with everything its Run needs to resume:
//!   the suspended tool call, a result for every other call of its turn, the
//!   Run's own settings, and how the request was settled once it was.
//!
//! It is self-sufficient: the kernel's `suspend.json` (core/suspend_state.zig)
//! is overwritten in place without fsync and does not keep every sibling, so
//! a SessionHost does not use it. The file is written whole and durably (a
//! temporary file, fsync, rename) by the Session's driver, or by `close` once
//! the driver has stopped; it is read when the Session is opened. One writer
//! at a time, so no lock.
//!
//! A field this version does not know is ignored, so a later version may add
//! one; a field this version must not ignore comes with a new `v`. A file
//! this version cannot read is never written over (`SessionHost`).

const std = @import("std");
const pfs = @import("platform").fs;

pub const FILE_NAME = "ui_requests.json";
pub const VERSION: u32 = 1;

pub const State = struct {
    v: u32 = VERSION,
    /// The id the next UI request of the Session takes.
    next_id: u64 = 1,
    /// The request a suspended Run waits for, or null.
    suspended: ?Suspended = null,
};

/// How a suspended Run resumes. `answer`: the answer to the question or
/// custom UI it suspended on becomes the suspended tool call's result. A
/// permission decision for a suspended tool call, which needs the kernel to
/// run the tool on resume, would be another kind; this version reads none.
pub const Kind = enum { answer };

pub const Suspended = struct {
    kind: Kind,
    id: u64,
    /// The request's `ui_request` line, announced again as is.
    announcement: []const u8,
    /// The suspended tool call and its tool.
    tool_use_id: []const u8,
    tool_name: []const u8,
    /// A result for every other call of the suspended turn, in the turn's
    /// order: what ran beside the suspended call, and, for a call that never
    /// ran (denied, deferred), a result that says so.
    completed: []const Result = &.{},
    /// The suspended Run's own settings, which the Run that resumes it keeps.
    trace_id: ?[]const u8 = null,
    max_turns: u32,
    stream_retry_budget: u8 = 0,
    /// Wall-clock milliseconds at which the request expires unanswered
    /// (`Options.ui_request_timeout_ms`); null never.
    expires_at_ms: ?i64 = null,
    /// How the request was settled, once it was: recorded before the answer
    /// enters the conversation and cleared after the resumed Run's transcript
    /// is written, so the next open applies it, unless the transcript already
    /// holds the call's result. Null while it waits for an answer.
    settled: ?Settled = null,
};

/// One tool result, as it enters the conversation on resume.
pub const Result = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool,
};

pub const Outcome = enum { answered, cancelled };

pub const Settled = struct {
    outcome: Outcome,
    /// `answered`: the answer, as the client sent it (JSON text).
    answer: ?[]const u8 = null,
    /// `answered`: who gave it, when the answer named them.
    by: ?[]const u8 = null,
    /// `cancelled` by an interrupt: the resumed Run stops at once.
    stop: bool = false,
};

pub const LoadError = error{
    /// Corrupt, or written by another version: left in place for it.
    UnreadableState,
    OutOfMemory,
};

/// The Session's state from `dir`, allocated in `arena`; null when there is
/// no file.
pub fn load(arena: std.mem.Allocator, dir: []const u8) LoadError!?State {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/" ++ FILE_NAME, .{dir}) catch return error.UnreadableState;
    if (!pfs.exists(path.ptr)) return null;
    const bytes = readAll(arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnreadableState,
    };
    const state = std.json.parseFromSliceLeaky(State, arena, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnreadableState,
    };
    if (state.v != VERSION or state.next_id == 0) return error.UnreadableState;
    if (state.suspended) |suspended| {
        if (suspended.id == 0 or suspended.id >= state.next_id) return error.UnreadableState;
        if (suspended.settled) |settled| {
            if (settled.outcome == .answered and settled.answer == null) return error.UnreadableState;
        }
    }
    return state;
}

/// The `next_id` of a file `load` refuses, if it still has a readable one:
/// the ids it handed out are below it.
pub fn peekNextId(arena: std.mem.Allocator, dir: []const u8) ?u64 {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/" ++ FILE_NAME, .{dir}) catch return null;
    const bytes = readAll(arena, path) catch return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return null;
    if (value != .object) return null;
    return switch (value.object.get("next_id") orelse return null) {
        .integer => |n| if (n > 0) @intCast(n) else null,
        else => null,
    };
}

/// Replaces the Session's state in `dir`, durably. `scratch` holds the
/// encoding for the call.
pub fn store(scratch: std.mem.Allocator, dir: []const u8, state: State) !void {
    const bytes = try std.json.Stringify.valueAlloc(scratch, state, .{});
    defer scratch.free(bytes);
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/" ++ FILE_NAME, .{dir});
    var temp_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const temp = try std.fmt.bufPrintZ(&temp_buf, "{s}/" ++ FILE_NAME ++ ".tmp", .{dir});
    const fd = pfs.open(temp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    var open = true;
    defer if (open) {
        _ = pfs.close(fd);
    };
    var written: usize = 0;
    while (written < bytes.len) {
        const n = pfs.write(fd, bytes[written..]);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
    try pfs.fsyncChecked(fd);
    _ = pfs.close(fd);
    open = false;
    if (pfs.renameReplace(temp.ptr, path.ptr) != 0) return error.RenameFailed;
}

fn readAll(arena: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    var bytes: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try bytes.appendSlice(arena, buf[0..@intCast(n)]);
    }
    return bytes.items;
}

// ============================================================================
// Tests
// ============================================================================

test "ui_request_store: no file, a round trip with a settled suspension, and what it refuses" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    try std.testing.expect((try load(arena.allocator(), dir)) == null);
    try store(a, dir, .{ .next_id = 3 });
    const empty = (try load(arena.allocator(), dir)).?;
    try std.testing.expectEqual(@as(u64, 3), empty.next_id);
    try std.testing.expect(empty.suspended == null);

    try store(a, dir, .{ .next_id = 8, .suspended = .{
        .kind = .answer,
        .id = 7,
        .announcement = "{\"v\":1,\"type\":\"ui_request\",\"id\":7}",
        .tool_use_id = "tu_q",
        .tool_name = "AskUserQuestion",
        .completed = &.{
            .{ .tool_use_id = "tu_w", .content = "{\"ok\":true}", .is_error = false },
            .{ .tool_use_id = "tu_r", .content = "{\"error\":\"NotRun\"}", .is_error = true },
        },
        .trace_id = "t-1",
        .max_turns = 40,
        .stream_retry_budget = 2,
        .expires_at_ms = 1_700_000_000_000,
        .settled = .{ .outcome = .answered, .answer = "{\"answers\":[\"Ship\"]}", .by = "alice" },
    } });
    const held = (try load(arena.allocator(), dir)).?;
    const suspended = held.suspended.?;
    try std.testing.expectEqual(@as(u64, 7), suspended.id);
    try std.testing.expectEqualStrings("{\"v\":1,\"type\":\"ui_request\",\"id\":7}", suspended.announcement);
    try std.testing.expectEqual(@as(usize, 2), suspended.completed.len);
    try std.testing.expectEqualStrings("tu_r", suspended.completed[1].tool_use_id);
    try std.testing.expect(suspended.completed[1].is_error);
    try std.testing.expectEqualStrings("t-1", suspended.trace_id.?);
    try std.testing.expectEqual(@as(u8, 2), suspended.stream_retry_budget);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000_000), suspended.expires_at_ms);
    try std.testing.expectEqual(Outcome.answered, suspended.settled.?.outcome);
    try std.testing.expectEqualStrings("alice", suspended.settled.?.by.?);
    var temp_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    try std.testing.expect(!pfs.exists((try std.fmt.bufPrintZ(&temp_buf, "{s}/" ++ FILE_NAME ++ ".tmp", .{dir})).ptr));

    const unreadable = [_][]const u8{
        "not json",
        "{\"v\":2,\"next_id\":1,\"suspended\":null}",
        "{\"v\":1,\"next_id\":0,\"suspended\":null}",
        // A kind this version does not know (a later permission decision).
        "{\"v\":1,\"next_id\":3,\"suspended\":{\"kind\":\"permission\",\"id\":2,\"announcement\":\"\",\"tool_use_id\":\"t\",\"tool_name\":\"Write\",\"max_turns\":1}}",
        // The suspended request's id must have been handed out.
        "{\"v\":1,\"next_id\":2,\"suspended\":{\"kind\":\"answer\",\"id\":2,\"announcement\":\"\",\"tool_use_id\":\"t\",\"tool_name\":\"AskUserQuestion\",\"max_turns\":1}}",
    };
    for (unreadable) |bytes| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = FILE_NAME, .data = bytes });
        try std.testing.expectError(error.UnreadableState, load(arena.allocator(), dir));
    }
    // Refused, a file still tells where its ids went up to, when it can.
    try std.testing.expectEqual(@as(?u64, 2), peekNextId(arena.allocator(), dir));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = FILE_NAME, .data = "not json" });
    try std.testing.expectEqual(@as(?u64, null), peekNextId(arena.allocator(), dir));

    // A field it does not know, beside those it does, is read past.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = FILE_NAME, .data = "{\"v\":1,\"next_id\":9,\"later\":true,\"suspended\":null}" });
    try std.testing.expectEqual(@as(u64, 9), (try load(arena.allocator(), dir)).?.next_id);
}
