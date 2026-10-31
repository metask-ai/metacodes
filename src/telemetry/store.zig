//! The session's span store: `<session dir>/spans.jsonl`.
//!
//! One OTLP/JSON `Span` object per line, appended as each span ends. It is the
//! source of the web UI's trace view (`GET /spans`, `GET /trace`), so a resumed
//! session shows every earlier Run as well, and it holds exactly what the OTLP
//! exporter sends, plus message content: the file sits next to the transcript,
//! which already holds the same content at the same trust level. Content is
//! still cut at `recorder.MAX_RECORDED_CONTENT_BYTES` per attribute.
//!
//! Each span is written with one `write` on an `O_APPEND` descriptor. A reader
//! keeps only complete lines, so it never sees half a span while a Run is
//! appending.

const std = @import("std");
const pfs = @import("platform").fs;
const otlp = @import("otlp.zig");
const span_mod = @import("span.zig");
const recorder = @import("recorder.zig");
const log = @import("../util/log.zig");

pub const FILE_NAME = "spans.jsonl";
/// The newest part of a store this large is served; older spans are skipped.
pub const MAX_READ_BYTES: usize = 32 * 1024 * 1024;

pub const local_policy: otlp.ContentPolicy = .{ .include = true, .max_content_bytes = recorder.MAX_RECORDED_CONTENT_BYTES };

/// A session directory other threads may read while the driver replaces it
/// (`/clear` starts a new session directory): the web server's `GET /spans`
/// copies it under the cell's lock instead of borrowing the App's string.
pub const DirCell = struct {
    mutex: @import("platform").sync.Mutex = .{},
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *DirCell, dir: ?[]const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const d = dir orelse {
            self.len = 0;
            return;
        };
        if (d.len > self.buf.len) {
            self.len = 0;
            return;
        }
        @memcpy(self.buf[0..d.len], d);
        self.len = d.len;
    }

    /// The directory copied into `out`, or null when there is none.
    pub fn copy(self: *DirCell, out: []u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == 0 or self.len > out.len) return null;
        @memcpy(out[0..self.len], self.buf[0..self.len]);
        return out[0..self.len];
    }
};

pub const SessionStore = struct {
    gpa: std.mem.Allocator,
    /// `<dir>/spans.jsonl`, NUL-terminated, owned.
    path: [:0]u8,
    warned: bool = false,

    pub fn init(gpa: std.mem.Allocator, session_dir: []const u8) error{OutOfMemory}!SessionStore {
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, session_dir, "/\\"), FILE_NAME }, 0);
        return .{ .gpa = gpa, .path = path };
    }

    pub fn deinit(self: *SessionStore) void {
        self.gpa.free(self.path);
    }

    pub fn sink(self: *SessionStore) recorder.Sink {
        return .{ .ctx = @ptrCast(self), .onEnd = onEnd };
    }

    fn onEnd(ctx: *anyopaque, s: *const span_mod.Span) void {
        const self: *SessionStore = @ptrCast(@alignCast(ctx));
        self.append(s) catch |err| {
            if (self.warned) return;
            self.warned = true;
            log.warn("otel", "session span store {s} not written: {s}", .{ self.path, @errorName(err) });
        };
    }

    pub fn append(self: *SessionStore, s: *const span_mod.Span) !void {
        const json = try otlp.encodeSpanJson(self.gpa, s, local_policy);
        defer self.gpa.free(json);
        // One write per span: the newline goes out with it.
        const line = try std.mem.concat(self.gpa, u8, &.{ json, "\n" });
        defer self.gpa.free(line);
        const fd = try pfs.openZ(self.path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600);
        defer pfs.close(fd);
        if (!pfs.writeAll(fd, line)) return error.WriteFailed;
    }
};

/// The store's spans as one OTLP/JSON `ExportTraceServiceRequest`, or an
/// empty request when the session has none yet. Caller frees.
pub fn readAsRequest(gpa: std.mem.Allocator, session_dir: []const u8, service_version: []const u8) error{OutOfMemory}![]u8 {
    if (session_dir.len == 0) return emptyRequest(gpa, service_version);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ std.mem.trimEnd(u8, session_dir, "/\\"), FILE_NAME }) catch
        return emptyRequest(gpa, service_version);
    const bytes = readTail(gpa, path) catch return emptyRequest(gpa, service_version);
    defer gpa.free(bytes);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        // The last piece has no newline yet: a span being written.
        if (it.peek() == null) break;
        if (line.len < 2 or line[0] != '{' or line[line.len - 1] != '}') continue;
        try lines.append(gpa, line);
    }
    return writeRequest(gpa, service_version, lines.items);
}

fn emptyRequest(gpa: std.mem.Allocator, service_version: []const u8) error{OutOfMemory}![]u8 {
    return writeRequest(gpa, service_version, &.{});
}

fn writeRequest(gpa: std.mem.Allocator, service_version: []const u8, spans: []const []const u8) error{OutOfMemory}![]u8 {
    const resource = [_]span_mod.Attribute{
        span_mod.Attribute.str("service.name", "metacodes"),
        span_mod.Attribute.str("service.version", service_version),
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    otlp.writeRequestJson(&out.writer, .{ .attributes = &resource }, .{ .version = service_version }, spans) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// The whole file, or its last `MAX_READ_BYTES` starting at a line boundary.
fn readTail(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = try pfs.openZ(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer pfs.close(fd);
    const size = pfs.lseek(fd, 0, .end);
    if (size < 0) return error.ReadFailed;
    const total: usize = @intCast(size);
    const start = total -| MAX_READ_BYTES;
    if (pfs.lseek(fd, @intCast(start), .set) < 0) return error.ReadFailed;
    const buf = try gpa.alloc(u8, total - start);
    errdefer gpa.free(buf);
    var off: usize = 0;
    while (off < buf.len) {
        const n = try pfs.readZ(fd, buf[off..]);
        if (n == 0) break;
        off += n;
    }
    if (start == 0) return gpa.realloc(buf, off);
    // Skip the partial first line of a cut file.
    const nl = std.mem.indexOfScalar(u8, buf[0..off], '\n') orelse off;
    const kept = off - @min(off, nl + 1);
    std.mem.copyForwards(u8, buf[0..kept], buf[off - kept .. off]);
    return gpa.realloc(buf, kept);
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "otel: spans appended to the store come back as one OTLP/JSON request, partial tail skipped" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    // No store yet: an empty request, not an error.
    const empty = try readAsRequest(a, dir, "9.9.9");
    defer a.free(empty);
    try testing.expect(std.mem.indexOf(u8, empty, "\"spans\":[]") != null);

    var store = try SessionStore.init(a, dir);
    defer store.deinit();
    const attrs = [_]span_mod.Attribute{span_mod.Attribute.text("gen_ai.tool.call.result", "kept locally")};
    var s: span_mod.Span = .{
        .trace_id = span_mod.TraceId.random(),
        .span_id = span_mod.SpanId.random(),
        .name = "execute_tool Read",
        .start_unix_nano = 10,
        .end_unix_nano = 20,
        .attributes = &attrs,
    };
    try store.append(&s);
    s.span_id = span_mod.SpanId.random();
    s.name = "turn 1";
    try store.append(&s);
    // A writer caught mid-line.
    {
        const fd = try pfs.openZ(store.path, .{ .ACCMODE = .WRONLY, .APPEND = true }, 0);
        defer pfs.close(fd);
        try testing.expect(pfs.writeAll(fd, "{\"traceId\":\"half"));
    }

    const body = try readAsRequest(a, dir, "9.9.9");
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const spans = parsed.value.object.get("resourceSpans").?.array.items[0].object.get("scopeSpans").?.array.items[0].object.get("spans").?.array.items;
    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expectEqualStrings("execute_tool Read", spans[0].object.get("name").?.string);
    try testing.expectEqualStrings("turn 1", spans[1].object.get("name").?.string);
    // The local store keeps content.
    try testing.expect(std.mem.indexOf(u8, body, "kept locally") != null);
}
