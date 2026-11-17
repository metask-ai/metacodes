//! A message a web or daemon client submits to a session — `POST /message`
//! (`--web`, `serve`), `POST /s/<id>/message` (`serve --sessions N`) and the
//! UDS `message` op — and the queue that carries it from the transport thread
//! to the session's driver thread.
//!
//! A submission is the prompt text plus optional per-message configuration,
//! `model` and `permission_mode`. An omitted field, or JSON `null`, keeps what
//! is in force; nothing is ever reset. The transport checks what it can without
//! touching the App — the permission mode is a closed vocabulary — and refuses
//! a bad field before anything is queued. Whether a model can be used depends
//! on the App's provider and catalog, so the driver checks it when it takes the
//! submission (`web/session.zig` `startSubmission`).
//!
//! Other fields are ignored, except one a client relies on for safety: an
//! `idempotency_key` is refused, because these hosts do not de-duplicate
//! (#447). Ignored, it let a retried delivery run twice while the client
//! believed it could not. `core/session_host.zig` takes it.
//!
//! The terminal's queue (`repl/msg_queue.zig`) stays a plain text queue: the
//! TUI has no per-message configuration.

const std = @import("std");
const sync = @import("platform").sync;
const types = @import("../types.zig");
const permission_mode = @import("../permission/mode.zig");

/// One queued message. Slices are owned by the queue's allocator once popped.
pub const Submission = struct {
    /// Prompt text, trimmed and never empty.
    text: []u8,
    /// Model for this and later turns, as the client named it (a tier name
    /// resolves on the driver). null = keep the active model.
    model: ?[]u8 = null,
    /// Permission mode for this and later turns. null = keep the active mode.
    permission_mode: ?types.PermissionMode = null,

    pub fn deinit(self: *Submission, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.model) |m| allocator.free(m);
        self.* = undefined;
    }
};

/// A parsed message whose slices borrow the request bytes or the parse arena.
pub const Request = struct {
    text: []const u8,
    model: ?[]const u8 = null,
    permission_mode: ?types.PermissionMode = null,
};

pub const ParseError = error{
    /// No text, only whitespace, or a JSON object without a string `text`.
    EmptyText,
    /// `model` is present but not a non-empty string.
    InvalidModel,
    /// `permission_mode` is present but not a mode name `permission/mode.zig`
    /// `parseName` accepts.
    InvalidPermissionMode,
    /// `idempotency_key` is present and not null: this host cannot honor it.
    UnsupportedIdempotencyKey,
    OutOfMemory,
};

/// The reply text for a refused message (static; no JSON escaping needed).
pub fn reason(err: ParseError) []const u8 {
    return switch (err) {
        error.EmptyText => "empty message",
        error.InvalidModel => "invalid model: expected a non-empty string",
        error.InvalidPermissionMode => "invalid permission_mode (default, acceptEdits, auto, dontAsk, bypassPermissions)",
        error.UnsupportedIdempotencyKey => "idempotency_key not supported: this host does not de-duplicate messages",
        error.OutOfMemory => "out of memory",
    };
}

/// Body of `POST /message`. A JSON object is read field by field (other
/// fields are ignored). Any other body — not JSON, or JSON that is not an
/// object — is the text itself, as it was before messages carried
/// configuration.
pub fn parseHttpBody(arena: std.mem.Allocator, body: []const u8) ParseError!Request {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .text = try trimmedText(body) },
    };
    if (value != .object) return .{ .text = try trimmedText(body) };
    return parseObject(value.object);
}

/// `{"text":...,"model":...,"permission_mode":...}` — the HTTP body and the
/// UDS `message` request share this reading. The result borrows `object`.
pub fn parseObject(object: std.json.ObjectMap) ParseError!Request {
    if (object.get("idempotency_key")) |value| {
        if (value != .null) return error.UnsupportedIdempotencyKey;
    }
    const text_value = object.get("text") orelse return error.EmptyText;
    if (text_value != .string) return error.EmptyText;
    var request: Request = .{ .text = try trimmedText(text_value.string) };
    if (object.get("model")) |value| switch (value) {
        .null => {},
        .string => |raw| {
            const model = std.mem.trim(u8, raw, " \t\r\n");
            if (model.len == 0) return error.InvalidModel;
            request.model = model;
        },
        else => return error.InvalidModel,
    };
    if (object.get("permission_mode")) |value| switch (value) {
        .null => {},
        .string => |name| request.permission_mode = permission_mode.parseName(name) orelse return error.InvalidPermissionMode,
        else => return error.InvalidPermissionMode,
    };
    return request;
}

fn trimmedText(raw: []const u8) ParseError![]const u8 {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return error.EmptyText;
    return text;
}

/// FIFO from the transport threads (push) to the session driver (popFront).
pub const SubmissionQueue = struct {
    /// Thread-safe: transport threads allocate concurrently.
    allocator: std.mem.Allocator,
    items: std.ArrayList(Submission) = .empty,
    mutex: sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) SubmissionQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SubmissionQueue) void {
        for (self.items.items) |*s| s.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    /// Queue a copy of `request`. false = out of memory, nothing queued.
    pub fn push(self: *SubmissionQueue, request: Request) bool {
        var owned: Submission = .{
            .text = self.allocator.dupe(u8, request.text) catch return false,
            .permission_mode = request.permission_mode,
        };
        if (request.model) |m| owned.model = self.allocator.dupe(u8, m) catch {
            owned.deinit(self.allocator);
            return false;
        };
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        self.items.append(self.allocator, owned) catch {
            owned.deinit(self.allocator);
            return false;
        };
        return true;
    }

    /// The oldest submission; the caller owns it (`deinit` with this queue's
    /// allocator). null when empty.
    pub fn popFront(self: *SubmissionQueue) ?Submission {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    pub fn len(self: *SubmissionQueue) usize {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        return self.items.items.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn parseForTest(arena: *std.heap.ArenaAllocator, body: []const u8) ParseError!Request {
    return parseHttpBody(arena.allocator(), body);
}

test "parseHttpBody: JSON text (escapes decoded), plain text, empty refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("hi there", (try parseForTest(&arena, "{\"text\":\"hi there\"}")).text);
    try testing.expectEqualStrings("line1\nline2", (try parseForTest(&arena, "{\"text\":\"line1\\nline2\"}")).text);
    try testing.expectEqualStrings("raw body", (try parseForTest(&arena, "  raw body\n")).text);
    // Malformed JSON and JSON that is not an object stay plain text, as before.
    try testing.expectEqualStrings("{\"text\":", (try parseForTest(&arena, "{\"text\":")).text);
    try testing.expectEqualStrings("42", (try parseForTest(&arena, "42")).text);
    try testing.expectError(error.EmptyText, parseForTest(&arena, "   "));
    try testing.expectError(error.EmptyText, parseForTest(&arena, "{\"nottext\":1}"));
    try testing.expectError(error.EmptyText, parseForTest(&arena, "{\"text\":5}"));
    try testing.expectError(error.EmptyText, parseForTest(&arena, "{\"text\":\"  \"}"));
}

test "parseHttpBody: omitted or null configuration keeps what is in force" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bare = try parseForTest(&arena, "{\"text\":\"go\"}");
    try testing.expectEqual(@as(?[]const u8, null), bare.model);
    try testing.expectEqual(@as(?types.PermissionMode, null), bare.permission_mode);
    const nulls = try parseForTest(&arena, "{\"text\":\"go\",\"model\":null,\"permission_mode\":null}");
    try testing.expectEqual(@as(?[]const u8, null), nulls.model);
    try testing.expectEqual(@as(?types.PermissionMode, null), nulls.permission_mode);
    // Plain text never carries configuration.
    const plain = try parseForTest(&arena, "model: x");
    try testing.expectEqual(@as(?[]const u8, null), plain.model);
}

test "parseHttpBody: model and permission_mode read and validated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const full = try parseForTest(&arena, "{\"text\":\"go\",\"model\":\" claude-opus-4-6 \",\"permission_mode\":\"acceptEdits\",\"extra\":true}");
    try testing.expectEqualStrings("go", full.text);
    try testing.expectEqualStrings("claude-opus-4-6", full.model.?);
    try testing.expectEqual(types.PermissionMode.accept_edits, full.permission_mode.?);
    // The spellings `/mode` accepts (one parser: permission/mode.zig parseName).
    try testing.expectEqual(types.PermissionMode.accept_edits, (try parseForTest(&arena, "{\"text\":\"go\",\"permission_mode\":\"accept-edits\"}")).permission_mode.?);
    try testing.expectEqual(types.PermissionMode.bypass_permissions, (try parseForTest(&arena, "{\"text\":\"go\",\"permission_mode\":\"bypass_permissions\"}")).permission_mode.?);
    try testing.expectError(error.InvalidPermissionMode, parseForTest(&arena, "{\"text\":\"go\",\"permission_mode\":\"plan\"}"));
    try testing.expectError(error.InvalidPermissionMode, parseForTest(&arena, "{\"text\":\"go\",\"permission_mode\":\"\"}"));
    try testing.expectError(error.InvalidPermissionMode, parseForTest(&arena, "{\"text\":\"go\",\"permission_mode\":1}"));
    try testing.expectError(error.InvalidModel, parseForTest(&arena, "{\"text\":\"go\",\"model\":\"\"}"));
    try testing.expectError(error.InvalidModel, parseForTest(&arena, "{\"text\":\"go\",\"model\":\"  \"}"));
    try testing.expectError(error.InvalidModel, parseForTest(&arena, "{\"text\":\"go\",\"model\":[\"x\"]}"));
}

test "parseHttpBody: an idempotency_key is refused, not ignored; null is absent; typed fields are ignored (#447)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnsupportedIdempotencyKey, parseForTest(&arena, "{\"text\":\"go\",\"idempotency_key\":\"im:evt-0001\"}"));
    try testing.expectError(error.UnsupportedIdempotencyKey, parseForTest(&arena, "{\"text\":\"go\",\"idempotency_key\":7}"));
    // Refused for what the host cannot do, before the text is even read.
    try testing.expectError(error.UnsupportedIdempotencyKey, parseForTest(&arena, "{\"idempotency_key\":\"k\"}"));
    try testing.expectEqualStrings("go", (try parseForTest(&arena, "{\"text\":\"go\",\"idempotency_key\":null}")).text);
    const typed = try parseForTest(&arena, "{\"text\":\"go\",\"source\":\"im:lark\",\"kind\":\"message\",\"attributes\":{\"chat\":\"C1\"}}");
    try testing.expectEqualStrings("go", typed.text);
    // The reply carries the reason whole: `{"error":"<reason>"}` and
    // `{"ok":false,"error":"<reason>"}` fit their 192-byte buffers.
    try testing.expect(reason(error.UnsupportedIdempotencyKey).len + "{\"ok\":false,\"error\":\"\"}".len <= 192);
}

test "SubmissionQueue: FIFO, owned copies, leftovers freed by deinit" {
    var q = SubmissionQueue.init(testing.allocator);
    defer q.deinit();
    var text_buf = "first".*;
    try testing.expect(q.push(.{ .text = &text_buf, .model = "m", .permission_mode = .auto }));
    try testing.expect(q.push(.{ .text = "second" }));
    try testing.expect(q.push(.{ .text = "left over", .model = "kept" }));
    text_buf[0] = 'X'; // the queue holds its own copy
    try testing.expectEqual(@as(usize, 3), q.len());

    var a = q.popFront().?;
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("first", a.text);
    try testing.expectEqualStrings("m", a.model.?);
    try testing.expectEqual(types.PermissionMode.auto, a.permission_mode.?);
    var b = q.popFront().?;
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("second", b.text);
    try testing.expectEqual(@as(?[]u8, null), b.model);
    try testing.expectEqual(@as(usize, 1), q.len());
}

test "SubmissionQueue.push: out of memory queues nothing and leaks nothing" {
    var fail_index: usize = 0;
    while (fail_index < 3) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var q = SubmissionQueue.init(failing.allocator());
        defer q.deinit();
        try testing.expect(!q.push(.{ .text = "t", .model = "m" }));
        try testing.expectEqual(@as(usize, 0), q.len());
    }
}
