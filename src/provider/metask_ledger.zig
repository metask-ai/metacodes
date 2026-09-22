//! Durable per-request billing ledger for Metask gateway calls.

const std = @import("std");
const pfs = @import("platform").fs;
const paths = @import("platform").paths;
const fs_util = @import("../util/fs.zig");
const json_util = @import("../util/json.zig");

pub const Record = struct {
    schema_version: u32 = 1,
    /// Unix epoch milliseconds, serialized as the contract's `ts` field.
    ts: i64,
    session_id: []const u8,
    provider_id: []const u8 = "metask",
    protocol: []const u8,
    model: []const u8,
    local_request_id: []const u8,
    server_request_id: []const u8,
    http_status: u16,
    outcome: []const u8,
    retry_attempt: u32 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,
    wall_elapsed_ms: u64 = 0,
};

pub fn ledgerPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("METACODES_LEDGER_DIR")) |raw|
        return std.fmt.allocPrint(allocator, "{s}/metask.ndjson", .{std.mem.trimEnd(u8, std.mem.span(raw), "/")});
    const home = paths.homeDir() orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.metacodes/ledger/metask.ndjson", .{home});
}

pub fn render(allocator: std.mem.Allocator, record: Record) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"schema_version\":");
    const head = try std.fmt.allocPrint(allocator, "{d},\"ts\":{d},\"session_id\":", .{ record.schema_version, record.ts });
    defer allocator.free(head);
    try out.appendSlice(allocator, head);
    try jsonString(allocator, &out, record.session_id);
    try out.appendSlice(allocator, ",\"provider_id\":");
    try jsonString(allocator, &out, record.provider_id);
    try out.appendSlice(allocator, ",\"protocol\":");
    try jsonString(allocator, &out, record.protocol);
    try out.appendSlice(allocator, ",\"model\":");
    try jsonString(allocator, &out, record.model);
    try out.appendSlice(allocator, ",\"local_request_id\":");
    try jsonString(allocator, &out, record.local_request_id);
    try out.appendSlice(allocator, ",\"server_request_id\":");
    try jsonString(allocator, &out, record.server_request_id);
    const nums = try std.fmt.allocPrint(allocator, ",\"http_status\":{d},\"outcome\":", .{record.http_status});
    defer allocator.free(nums);
    try out.appendSlice(allocator, nums);
    try jsonString(allocator, &out, record.outcome);
    const tail = try std.fmt.allocPrint(allocator, ",\"retry_attempt\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_creation_tokens\":{d},\"wall_elapsed_ms\":{d}}}\n", .{ record.retry_attempt, record.input_tokens, record.output_tokens, record.cache_read_tokens, record.cache_creation_tokens, record.wall_elapsed_ms });
    defer allocator.free(tail);
    try out.appendSlice(allocator, tail);
    return out.toOwnedSlice(allocator);
}

pub fn append(allocator: std.mem.Allocator, record: Record) !void {
    const path = try ledgerPath(allocator);
    defer allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try fs_util.mkdirParents(dir);
    const line = try render(allocator, record);
    defer allocator.free(line);
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .NOFOLLOW = true }, 0o600);
    if (fd < 0) return error.WriteFailed;
    defer pfs.close(fd);
    var written: usize = 0;
    while (written < line.len) {
        const n = pfs.write(fd, line[written..]);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

pub fn read(allocator: std.mem.Allocator) ![]u8 {
    const path = try ledgerPath(allocator);
    defer allocator.free(path);
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return error.NotFound;
    defer pfs.close(fd);
    const info = try pfs.fileInfo(fd);
    if (info.size > 64 * 1024 * 1024) return error.FileTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(info.size));
    errdefer allocator.free(bytes);
    var n: usize = 0;
    while (n < bytes.len) {
        const got = try pfs.readZ(fd, bytes[n..]);
        if (got == 0) break;
        n += got;
    }
    return bytes[0..n];
}

fn jsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try json_util.serializeString(value, out, allocator);
}

test "Metask ledger renders one complete NDJSON record" {
    const line = try render(std.testing.allocator, .{
        .ts = 1,
        .session_id = "sess",
        .protocol = "anthropic_messages",
        .model = "m",
        .local_request_id = "local",
        .server_request_id = "req-1",
        .http_status = 200,
        .outcome = "completed",
        .input_tokens = 4,
        .output_tokens = 2,
    });
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));
    try std.testing.expect(std.mem.indexOf(u8, line, "\"ts\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"server_request_id\":\"req-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"input_tokens\":4") != null);
}

test "Metask ledger replaces invalid UTF-8 in string fields" {
    const line = try render(std.testing.allocator, .{
        .ts = 1,
        .session_id = "sess\x80\xe4\xbd",
        .protocol = "anthropic_messages",
        .model = "m\xff",
        .local_request_id = "local",
        .server_request_id = "req-1",
        .http_status = 200,
        .outcome = "completed\xc0\x80",
    });
    defer std.testing.allocator.free(line);

    // The ledger is NDJSON, so each line must be accepted as a valid UTF-8
    // JSON object even when a provider or session identifier supplied bytes
    // that were not UTF-8.
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, std.mem.trimEnd(u8, line, "\n"), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("sess\u{FFFD}\u{FFFD}\u{FFFD}", object.get("session_id").?.string);
    try std.testing.expectEqualStrings("m\u{FFFD}", object.get("model").?.string);
    try std.testing.expectEqualStrings("completed\u{FFFD}\u{FFFD}", object.get("outcome").?.string);
}
