//! Shared native-tool result writer.
//!
//! High-output first-party tools write their final representation into a
//! kernel-private Capture. Small complete results are lifted back to inline;
//! large or incomplete results are copied into the Session CAS without ever
//! materializing the whole payload.

const std = @import("std");
const artifact_store = @import("../core/tool_result_artifact.zig");
const tool_result = @import("../core/tool_result.zig");

pub const INLINE_DECISION_BYTES: usize = 64 * 1024;

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

pub fn finishCaptureAsBody(
    allocator: std.mem.Allocator,
    artifact_root: []const u8,
    capture: *artifact_store.Capture,
    media_type: tool_result.MediaType,
    capture_complete: bool,
) !tool_result.ToolResultBody {
    if (capture_complete and capture.bytes <= INLINE_DECISION_BYTES) {
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

    var body = try finishCaptureAsBody(allocator, root, &capture, .text_utf8, true);
    defer body.deinit(allocator);
    try std.testing.expect(body == .@"inline");
    try std.testing.expectEqualStrings("native-42", body.@"inline".bytes);
}
