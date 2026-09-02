//! Shared native-tool result writer.
//!
//! High-output first-party tools write their final representation into a
//! kernel-private Capture. Small complete results are lifted back to inline;
//! large or incomplete results are copied into the Session CAS without ever
//! materializing the whole payload.
//!
//! "Small" is the projection layer's own per-result budget, handed in by the
//! caller - never a constant of this file's. There used to be one, 64KB, which
//! is `PER_RESULT_MAX_BYTES` copied once more: on every window below 524,288
//! tokens it sat above `per_result_bytes` and left a dead zone in which a
//! result was lifted into memory here only to be spilled straight back to the
//! CAS by projection - the same bytes handled twice. The two layers decide
//! different things at different times (whether bytes enter memory at all,
//! versus how much the model sees), which is why they stay two layers; but
//! they decide against the same number.
//!
//! This file reads `per_result_bytes` and nothing else off the budget. The
//! turn budget is a projection concern - it depends on sibling results this
//! writer cannot see - and a guard test below keeps it that way.

const std = @import("std");
const artifact_store = @import("../core/tool_result_artifact.zig");
const tool_result = @import("../core/tool_result.zig");
const result_budget = @import("../core/result_budget.zig");

/// Unbuffered std.Io.Writer adapter over Capture. The vtable has only one
/// possible owner and latches the underlying typed error before presenting
/// std.Io.Writer's generic WriteFailed at formatting call sites.
pub const CaptureWriter = struct {
    capture: *artifact_store.Capture,
    writer: std.Io.Writer,
    failure: ?anyerror = null,

    pub fn init(capture: *artifact_store.Capture) CaptureWriter {
        return .{
            .capture = capture,
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
    }

    pub fn check(self: *const CaptureWriter) !void {
        if (self.failure) |failure| return failure;
    }

    fn drain(
        interface: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *CaptureWriter = @alignCast(@fieldParentPtr("writer", interface));
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.capture.write(bytes) catch |failure| {
                self.failure = failure;
                return error.WriteFailed;
            };
            consumed += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            self.capture.write(pattern) catch |failure| {
                self.failure = failure;
                return error.WriteFailed;
            };
            consumed += pattern.len;
        }
        return consumed;
    }
};

/// `budget` is the caller's `ctx.result_budget`, passed whole so a caller
/// cannot hand over a number it computed itself; only `per_result_bytes` is
/// read. An incomplete capture is always published: it has no complete inline
/// form, whatever its size.
pub fn finishCaptureAsBody(
    allocator: std.mem.Allocator,
    artifact_root: []const u8,
    capture: *artifact_store.Capture,
    media_type: tool_result.MediaType,
    capture_complete: bool,
    budget: result_budget.Budget,
) !tool_result.ToolResultBody {
    if (capture_complete and capture.bytes <= budget.per_result_bytes) {
        return tool_result.ToolResultBody.initInline(try capture.readRangeAlloc(
            allocator,
            0,
            @intCast(capture.bytes),
        ));
    }

    var spool = try artifact_store.Spool.begin(allocator, artifact_root);
    defer spool.deinit();
    try capture.copyRangeTo(&spool, 0, capture.bytes);
    var completed = try spool.finish();
    completed.receipt.capture_complete = capture_complete;
    return tool_result.ToolResultBody.fromCompletedSpool(completed, media_type);
}

pub fn copyAll(source: *artifact_store.Capture, destination: *artifact_store.Capture) !void {
    try source.rewind();
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try source.read(&buffer);
        if (count == 0) break;
        try destination.write(buffer[0..count]);
    }
}

test "CaptureWriter streams formatting and preserves small inline result" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    var capture = try artifact_store.Capture.begin(allocator, root, 1024);
    defer capture.deinit();
    var output = CaptureWriter.init(&capture);
    try output.writer.print("native-{d}", .{42});
    try output.check();
    try capture.seal();

    // `.floor` is the smallest budget there is; a 9-byte result must stay inline under it.
    var body = try finishCaptureAsBody(allocator, root, &capture, .text_utf8, true, .floor);
    defer body.deinit(allocator);
    try std.testing.expect(body == .@"inline");
    try std.testing.expectEqualStrings("native-42", body.@"inline".bytes);
}

/// Index just past the `)` that closes the call opened at `open` (the index of
/// its `(`), or null if unbalanced.
fn callEnd(src: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

test "guard: callers hand over ctx.result_budget verbatim, and this file reads only per_result_bytes" {
    // The behaviour tests in tests/component/inline_threshold_test.zig are the
    // real check. This one only closes the two ways the number could fork
    // again without any behaviour test noticing on the day it happens:
    // a caller passing a budget it derived itself, or this file starting to
    // read turn-level fields that belong to projection.
    //
    // Needles are spliced at comptime so this test's own source, which is
    // embedded below, cannot satisfy or trip them.
    const forbidden_here = .{ "per_" ++ "turn", "payload" ++ "Allowance", "INLINE_DECISION" ++ "_BYTES" };
    const self_src = @embedFile("result_spool.zig");
    inline for (forbidden_here) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, self_src, needle) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, self_src, "budget.per_result_bytes") != null);

    const callers = .{
        @embedFile("grep.zig"),
        @embedFile("mcp_resources.zig"),
        @embedFile("code_map.zig"),
        @embedFile("web_fetch.zig"),
        @embedFile("find_symbol.zig"),
    };
    var seen: usize = 0;
    inline for (callers) |src| {
        try std.testing.expect(std.mem.indexOf(u8, src, "INLINE_DECISION" ++ "_BYTES") == null);
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, src, cursor, "finishCaptureAsBody(")) |at| {
            const open = at + "finishCaptureAsBody".len;
            const end = callEnd(src, open) orelse return error.UnbalancedCall;
            const args = std.mem.trim(u8, src[open + 1 .. end - 1], " \t\r\n,");
            const last_comma = std.mem.lastIndexOfScalar(u8, args, ',') orelse return error.TooFewArguments;
            const last = std.mem.trim(u8, args[last_comma + 1 ..], " \t\r\n");
            try std.testing.expectEqualStrings("ctx.result_budget", last);
            seen += 1;
            cursor = end;
        }
    }
    try std.testing.expectEqual(@as(usize, 6), seen);
}
