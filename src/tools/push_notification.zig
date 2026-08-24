//! PushNotification:发桌面通知。
//!
//! cc-zig 简化版:
//!   - macOS:osascript -e 'display notification "<msg>" with title "MetaCode"'
//!   - Linux:notify-send "MetaCode" "<msg>"
//!   - 失败静默(通知非关键路径)
//!
//! Claude Code 还能推手机(Remote Control),cc-zig 不做 — 只本地桌面。
//!
//! Schema: message (必填), status (可选,proactive)

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const a = ctx.allocator;
    const message_raw = common.extractJsonArg(args, "message") orelse return error.MissingMessage;
    if (message_raw.len == 0) return error.EmptyMessage;
    // 反转义
    const message = try @import("../util/json.zig").unescapeString(message_raw, a);
    defer a.free(message);

    // 截断到 200 字符(对齐 Claude Code 建议)
    const truncated = if (message.len > 200) message[0..200] else message;

    const sent = sendNotification(a, truncated, ctx.abort) catch false;

    return try std.fmt.allocPrint(a, "{{\"sent\":{},\"message\":\"(notification dispatched)\"}}", .{sent});
}

fn sendNotification(a: std.mem.Allocator, message: []const u8, abort: ?*const @import("../util/abort.zig").AbortSignal) !bool {
    switch (builtin.os.tag) {
        .macos => {
            // osascript -e 'display notification "MSG" with title "MetaCode"'
            // 把 message 里的 " 转义成 \"
            const escaped = try escapeForAppleScript(a, message);
            defer a.free(escaped);
            const script = try std.fmt.allocPrintSentinel(a, "display notification \"{s}\" with title \"MetaCode\"", .{escaped}, 0);
            defer a.free(script);
            const argv = [_]?[*:0]const u8{ "/usr/bin/osascript", "-e", script.ptr, null };
            const out = common.spawnCaptureStdoutAbortableTimed(argv[0..], a, abort, 5_000) catch return false;
            a.free(out);
            return true;
        },
        .linux => {
            const msg_z = try a.dupeZ(u8, message);
            defer a.free(msg_z);
            const argv = [_]?[*:0]const u8{ "/usr/bin/env", "notify-send", "MetaCode", msg_z.ptr, null };
            const out = common.spawnCaptureStdoutAbortableTimed(argv[0..], a, abort, 5_000) catch return false;
            a.free(out);
            return true;
        },
        else => return false,
    }
}

fn escapeForAppleScript(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append(a, '\\');
        // AppleScript 字符串里换行用 \n 不安全,转空格
        if (c == '\n' or c == '\r') {
            try out.append(a, ' ');
        } else {
            try out.append(a, c);
        }
    }
    return try out.toOwnedSlice(a);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "PushNotification: missing message errors" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.MissingMessage, execute(&ctx, "{}"));
}

test "PushNotification: empty message errors" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.EmptyMessage, execute(&ctx, "{\"message\":\"\"}"));
}

test "escapeForAppleScript: quotes and newlines" {
    const a = testing.allocator;
    const r = try escapeForAppleScript(a, "say \"hi\"\nthere");
    defer a.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "\\\"hi\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, r, "\n") == null);
}

test "PushNotification: returns sent field (may be false in CI)" {
    const a = testing.allocator;
    const ctx = ToolContext.simple(a);
    const out = try execute(&ctx, "{\"message\":\"test notification\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"sent\":") != null);
}
