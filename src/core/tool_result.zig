//! Typed, ownership-safe tool-result data plane.
//!
//! Legacy tools return an owned inline slice through a thin adapter. Native
//! streaming tools, process plugins and embedding decorators may instead
//! return a completed artifact receipt, so the full payload never has to be
//! reconstructed merely to cross the dispatch boundary.

const std = @import("std");
const artifact_store = @import("tool_result_artifact.zig");
const tool_error = @import("tool_error.zig");
const result_budget = @import("result_budget.zig");
const util_json = @import("../util/json.zig");

pub const PROJECTION_SCHEMA = "metacodes.tool-result-projection.v1";
pub const ENVELOPE_PREFIX = "{\"schema_version\":\"" ++ PROJECTION_SCHEMA ++ "\",\"projection\":";
pub const MAX_STRUCTURED_ERROR_BYTES: usize = 1024 * 1024;

pub const MediaType = enum {
    text_utf8,
    json,
    binary,

    pub fn value(self: MediaType) []const u8 {
        return switch (self) {
            .text_utf8 => "text/plain; charset=utf-8",
            .json => "application/json",
            .binary => "application/octet-stream",
        };
    }
};

pub const InlineResult = struct {
    bytes: []u8,
    attachments: SealedHandles = .{},
};

pub const ArtifactReceipt = struct {
    stored: artifact_store.Receipt,
    preview: artifact_store.Preview,
    media_type: MediaType,
};
pub const SealedArtifact = struct {
    spool: artifact_store.SealedSpool,
    media_type: MediaType,
    capture_complete: bool,
    /// The largest result the producing tool would have kept inline had its
    /// publication failed at execution time; the batch commit boundary applies
    /// the same policy (`result_budget.retainInlineAfterFailedPublish`). Native
    /// tools keep the per-result ceiling; the MCP client keeps the bytes it
    /// already materialized up to its frame limit (#65).
    retain_inline_ceiling: u64 = result_budget.PER_RESULT_MAX_BYTES,
    /// Set when this handle is an *attachment* of an inline body rather than
    /// the body itself (#73): the Bash result JSON embeds one artifact id per
    /// channel under this label ("stdout", "stderr"). A failed publication
    /// withdraws that id from the JSON instead of leaving a dangling promise.
    attachment_label: ?[]const u8 = null,
};
/// The most handles one tool result carries: a `.sealed` body has one, a
/// Bash inline body has one attachment per channel (stdout, stderr).
pub const MAX_SEALED_HANDLES: usize = 2;

/// The sealed handles one tool result carries to the batch commit boundary
/// (#73): either the single handle of a `.sealed` body, or the attachments of
/// an inline body. Fixed capacity, no allocation; the handles own their
/// private spool files until `discard`/`deinit`.
pub const SealedHandles = struct {
    items: [MAX_SEALED_HANDLES]?SealedArtifact = .{ null, null },
    len: u8 = 0,

    pub fn isEmpty(self: *const SealedHandles) bool {
        return self.len == 0;
    }

    pub fn append(self: *SealedHandles, handle: SealedArtifact) error{TooManySealedHandles}!void {
        if (self.len >= MAX_SEALED_HANDLES) return error.TooManySealedHandles;
        self.items[self.len] = handle;
        self.len += 1;
    }

    /// Move the handles out; `self` is left empty.
    pub fn take(self: *SealedHandles) SealedHandles {
        const out = self.*;
        self.* = .{};
        return out;
    }

    pub fn slice(self: *SealedHandles) []?SealedArtifact {
        return self.items[0..self.len];
    }

    /// Unlink every still-sealed private file and release the handles.
    pub fn discard(self: *SealedHandles) void {
        for (self.slice()) |*maybe| {
            if (maybe.*) |*handle| handle.spool.discard();
        }
        self.deinit();
    }

    /// Release the handles; a still-sealed file is unlinked by `SealedSpool.deinit`.
    pub fn deinit(self: *SealedHandles) void {
        for (self.slice()) |*maybe| {
            if (maybe.*) |*handle| handle.spool.deinit();
        }
        self.* = .{};
    }

    /// Re-home every handle into `allocator` (see `SealedSpool.adopt`). On
    /// failure the handles are discarded and nothing dangles.
    pub fn adopt(self: *SealedHandles, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        for (self.slice()) |*maybe| {
            if (maybe.*) |*handle| {
                handle.spool = handle.spool.adopt(allocator) catch {
                    self.discard();
                    return error.OutOfMemory;
                };
            }
        }
    }
};

/// A validated, bounded model-visible error. Construction is deliberately
/// fallible so over-sized errors cannot enter `ToolResultBody` through the
/// supported API and crowd durable Conversation state.
pub const StructuredToolError = struct {
    encoded: []u8,
    category: ?tool_error.Category = null,

    pub fn init(allocator: std.mem.Allocator, encoded: []const u8) !StructuredToolError {
        if (encoded.len == 0 or encoded.len > MAX_STRUCTURED_ERROR_BYTES)
            return error.StructuredToolErrorTooLarge;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena.allocator(),
            encoded,
            .{ .duplicate_field_behavior = .@"error" },
        ) catch return error.InvalidStructuredToolError;
        if (parsed != .object) return error.InvalidStructuredToolError;
        const payload = parsed.object.get("error") orelse
            return error.InvalidStructuredToolError;
        if (payload != .object) return error.InvalidStructuredToolError;
        var category: ?tool_error.Category = null;
        if (payload.object.get("category")) |value| {
            if (value == .string)
                category = std.meta.stringToEnum(tool_error.Category, value.string);
        }
        return .{
            .encoded = try allocator.dupe(u8, encoded),
            .category = category,
        };
    }
};

pub const Rendered = struct {
    bytes: []const u8,
    owned: ?[]u8 = null,
    is_error: bool,

    pub fn deinit(self: *Rendered, allocator: std.mem.Allocator) void {
        if (self.owned) |bytes| allocator.free(bytes);
        self.* = undefined;
    }
};

pub const Taken = struct {
    bytes: []u8,
    is_error: bool,
};

pub const ToolResultBody = union(enum) {
    @"inline": InlineResult,
    artifact: ArtifactReceipt,
    sealed: SealedArtifact,
    structured_error: StructuredToolError,

    pub fn initInline(bytes: []u8) ToolResultBody {
        return .{ .@"inline" = .{ .bytes = bytes } };
    }

    pub fn initStructuredError(
        allocator: std.mem.Allocator,
        encoded: []const u8,
    ) !ToolResultBody {
        return .{ .structured_error = try StructuredToolError.init(allocator, encoded) };
    }

    /// Promote an oversized inline result into the artifact plane: the bytes
    /// are sealed as a `.sealed` body whose envelope the model sees, and the
    /// batch commit boundary publishes the blob (#73; before that this
    /// published during the call). The union changes tag only after the seal
    /// succeeds, so a failure leaves the inline body untouched. An inline body
    /// that carries attachments resolves them first — its bytes embed their
    /// ids, and a sealed body holds no second handle — which is the one place
    /// an attachment still publishes at execution time.
    pub fn promoteInline(
        self: *ToolResultBody,
        allocator: std.mem.Allocator,
        session_root: []const u8,
    ) !bool {
        const bytes = switch (self.*) {
            .@"inline" => |*inline_result| blk: {
                if (!inline_result.attachments.isEmpty()) {
                    inline_result.bytes = try resolveAttachments(allocator, inline_result.bytes, &inline_result.attachments);
                }
                break :blk inline_result.bytes;
            },
            .artifact, .sealed, .structured_error => return false,
        };
        var spool = try artifact_store.Spool.begin(allocator, session_root);
        defer spool.deinit(); // a no-op once `seal` has taken the buffers
        try spool.write(bytes);
        const sealed = try spool.seal();
        const media_type = detectMediaType(bytes);
        allocator.free(bytes);
        self.* = .{ .sealed = .{ .spool = sealed, .media_type = media_type, .capture_complete = true } };
        return true;
    }

    pub fn fromCompletedSpool(completed: artifact_store.CompletedSpool, media_type: MediaType) ToolResultBody {
        return .{ .artifact = .{
            .stored = completed.receipt,
            .preview = completed.preview,
            .media_type = media_type,
        } };
    }

    pub fn render(self: *const ToolResultBody, allocator: std.mem.Allocator) error{OutOfMemory}!Rendered {
        return switch (self.*) {
            .@"inline" => |result| .{ .bytes = result.bytes, .is_error = false },
            .structured_error => |result| .{ .bytes = result.encoded, .is_error = true },
            .artifact => |result| blk: {
                const encoded = try renderArtifactEnvelope(allocator, result);
                break :blk .{ .bytes = encoded, .owned = encoded, .is_error = false };
            },
            .sealed => |result| blk: {
                var receipt = result.spool.receipt();
                receipt.capture_complete = result.capture_complete;
                const encoded = try renderArtifactEnvelope(allocator, .{ .stored = receipt, .preview = result.spool.previewValue(), .media_type = result.media_type });
                break :blk .{ .bytes = encoded, .owned = encoded, .is_error = false };
            },
        };
    }

    pub fn modelVisibleBytes(self: *const ToolResultBody, allocator: std.mem.Allocator) error{OutOfMemory}!usize {
        var rendered = try self.render(allocator);
        defer rendered.deinit(allocator);
        return rendered.bytes.len;
    }

    /// Consume the body and return one owned, bounded model-visible slice.
    /// Sealed bodies publish immediately at this legacy edge and may therefore
    /// fail with the artifact publication errors formerly returned by the tool layer.
    /// Legacy adapters use this at their outermost compatibility edge; the
    /// typed dispatcher path keeps the union intact.
    pub fn takeModelBytes(self: *ToolResultBody, allocator: std.mem.Allocator) !Taken {
        return switch (self.*) {
            .@"inline" => |result| blk: {
                var handles = result.attachments;
                const bytes = try resolveAttachments(allocator, result.bytes, &handles);
                self.* = .{ .@"inline" = .{ .bytes = &.{} } };
                break :blk .{ .bytes = bytes, .is_error = false };
            },
            .structured_error => |result| blk: {
                self.* = .{ .@"inline" = .{ .bytes = &.{} } };
                break :blk .{ .bytes = result.encoded, .is_error = true };
            },
            .artifact => |result| blk: {
                const bytes = try renderArtifactEnvelope(allocator, result);
                self.* = .{ .@"inline" = .{ .bytes = &.{} } };
                break :blk .{ .bytes = bytes, .is_error = false };
            },
            .sealed => |*result| blk: {
                const completed = result.spool.publish() catch |err| {
                    const allowed = result_budget.retainInlineAfterFailedPublish(err, result.spool.receipt().bytes, result.capture_complete, result.retain_inline_ceiling);
                    if (!allowed) {
                        result.spool.deinit();
                        self.* = .{ .@"inline" = .{ .bytes = &.{} } };
                        return err;
                    }
                    const bytes = result.spool.readAllAlloc(allocator) catch |read_err| {
                        result.spool.deinit();
                        self.* = .{ .@"inline" = .{ .bytes = &.{} } };
                        return read_err;
                    };
                    result.spool.deinit();
                    self.* = .{ .@"inline" = .{ .bytes = &.{} } };
                    break :blk .{ .bytes = bytes, .is_error = false };
                };
                var receipt = completed.receipt;
                receipt.capture_complete = result.capture_complete;
                const bytes = try renderArtifactEnvelope(allocator, .{ .stored = receipt, .preview = completed.preview, .media_type = result.media_type });
                result.spool.deinit();
                self.* = .{ .@"inline" = .{ .bytes = &.{} } };
                break :blk .{ .bytes = bytes, .is_error = false };
            },
        };
    }

    pub fn rawBytes(self: *const ToolResultBody) u64 {
        return switch (self.*) {
            .@"inline" => |result| result.bytes.len,
            .artifact => |result| result.stored.bytes,
            .sealed => |result| result.spool.receipt().bytes,
            .structured_error => |result| result.encoded.len,
        };
    }

    pub fn deinit(self: *ToolResultBody, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .@"inline" => |result| {
                allocator.free(result.bytes);
                var handles = result.attachments;
                handles.discard();
            },
            .structured_error => |result| allocator.free(result.encoded),
            .artifact => {},
            .sealed => |*result| result.spool.deinit(),
        }
        self.* = undefined;
    }

    pub fn takeSealed(self: *ToolResultBody) ?SealedArtifact {
        return switch (self.*) {
            .sealed => |result| blk: {
                self.* = .{ .@"inline" = .{ .bytes = &.{} } };
                break :blk result;
            },
            else => null,
        };
    }
    pub fn takeSealedHandles(self: *ToolResultBody) SealedHandles {
        return switch (self.*) {
            .sealed => |result| blk: {
                var h = SealedHandles{};
                h.append(result) catch unreachable;
                self.* = .{ .@"inline" = .{ .bytes = &.{} } };
                break :blk h;
            },
            // The bytes stay with the body; only the handles move.
            .@"inline" => |*result| result.attachments.take(),
            else => .{},
        };
    }
};

/// Replace the first occurrence of `needle` in `haystack`; a copy of the
/// input when it does not occur.
fn replaceOnce(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) error{OutOfMemory}![]u8 {
    const pos = std.mem.indexOf(u8, haystack, needle) orelse return allocator.dupe(u8, haystack);
    const out = try allocator.alloc(u8, haystack.len - needle.len + replacement.len);
    @memcpy(out[0..pos], haystack[0..pos]);
    @memcpy(out[pos..][0..replacement.len], replacement);
    @memcpy(out[pos + replacement.len ..], haystack[pos + needle.len ..]);
    return out;
}

/// Withdraw one channel's artifact from a `metacodes.bash-result.v2` body whose
/// publication failed at the commit boundary (#73). Two exact substrings are
/// rewritten, both emitted by `bash.zig`'s `appendChannel` (a test there pins
/// the two producers together): `"<label>_artifact_id":"<id>"` becomes
/// `"<label>_artifact_id":null,"<label>_storage_error":"<code>"`, and the
/// recovery hint `,"<label>_recoverable":true,"<label>_read":{...}` becomes
/// `,"<label>_recoverable":false`. Either substring being absent leaves that
/// part unchanged; the result is always a fresh allocation.
pub fn withdrawAttachmentFromJson(
    allocator: std.mem.Allocator,
    json: []const u8,
    label: []const u8,
    artifact_id: []const u8,
    storage_error: []const u8,
) error{OutOfMemory}![]u8 {
    const id_needle = try std.fmt.allocPrint(allocator, "\"{s}_artifact_id\":\"{s}\"", .{ label, artifact_id });
    defer allocator.free(id_needle);
    const id_replacement = try std.fmt.allocPrint(allocator, "\"{s}_artifact_id\":null,\"{s}_storage_error\":\"{s}\"", .{ label, label, storage_error });
    defer allocator.free(id_replacement);
    const hint_needle = try std.fmt.allocPrint(
        allocator,
        ",\"{s}_recoverable\":true,\"{s}_read\":{{\"tool\":\"ReadArtifact\",\"artifact_id\":\"{s}\",\"offset\":0,\"limit_max\":32768}}",
        .{ label, label, artifact_id },
    );
    defer allocator.free(hint_needle);
    const hint_replacement = try std.fmt.allocPrint(allocator, ",\"{s}_recoverable\":false", .{label});
    defer allocator.free(hint_replacement);

    const first = try replaceOnce(allocator, json, id_needle, id_replacement);
    defer allocator.free(first);
    return replaceOnce(allocator, first, hint_needle, hint_replacement);
}

/// Publish the attachments of an inline body at the commit boundary (#73).
/// `bytes` is the rendered body (owned by the caller); when a publication
/// fails the corresponding id is withdrawn from it and the rewritten bytes are
/// returned (the input is freed); otherwise `bytes` is returned as is. The
/// handles are released either way. Handles that are not attachments
/// (`attachment_label == null`) are left to the caller.
pub fn resolveAttachments(allocator: std.mem.Allocator, bytes: []u8, handles: *SealedHandles) error{OutOfMemory}![]u8 {
    var out = bytes;
    for (handles.slice()) |*maybe| {
        const handle = if (maybe.*) |*value| value else continue;
        const label = handle.attachment_label orelse continue;
        if (handle.spool.publish()) |_| continue else |err| {
            const rewritten = try withdrawAttachmentFromJson(allocator, out, label, handle.spool.receipt().id(), artifact_store.storageErrorCode(err));
            allocator.free(out);
            out = rewritten;
        }
    }
    handles.deinit();
    return out;
}

pub fn renderArtifactEnvelope(allocator: std.mem.Allocator, result: ArtifactReceipt) error{OutOfMemory}![]u8 {
    return renderArtifactEnvelopeFallible(allocator, result) catch error.OutOfMemory;
}

fn renderArtifactEnvelopeFallible(allocator: std.mem.Allocator, result: ArtifactReceipt) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(ENVELOPE_PREFIX ++ "\"artifact\",\"artifact_id\":");
    try util_json.writeJsonString(writer, result.stored.id());
    try writer.writeAll(",\"media_type\":");
    try util_json.writeJsonString(writer, result.media_type.value());
    try writer.print(",\"original_bytes\":{d},\"sha256\":\"{s}\",\"capture_complete\":{s},\"recoverable\":true", .{
        result.stored.bytes,
        result.stored.sha256[0..],
        if (result.stored.capture_complete) "true" else "false",
    });
    try appendPreview(writer, &result.preview);
    try writer.writeAll(",\"read\":{\"tool\":\"ReadArtifact\",\"offset\":0,\"limit_max\":32768}}");
    return out.toOwnedSlice();
}

fn appendPreview(writer: *std.Io.Writer, preview: *const artifact_store.Preview) !void {
    const head = preview.headSlice();
    const tail = preview.tailSlice();
    const utf8 = isInlineUtf8(head) and isInlineUtf8(tail);
    try writer.writeAll(if (utf8) ",\"preview_encoding\":\"utf-8\"" else ",\"preview_encoding\":\"base64\"");
    try writer.writeAll(",\"preview_head\":");
    try appendPreviewPart(writer, head, utf8);
    try writer.writeAll(",\"preview_tail\":");
    try appendPreviewPart(writer, tail, utf8);
    try writer.print(",\"preview_head_bytes\":{d},\"preview_tail_bytes\":{d},\"omitted_bytes\":{d}", .{
        head.len,
        tail.len,
        preview.omittedBytes(),
    });
}

fn appendPreviewPart(writer: *std.Io.Writer, bytes: []const u8, utf8: bool) !void {
    if (utf8) return util_json.writeJsonString(writer, bytes);
    const encoder = std.base64.standard.Encoder;
    const encoded = try std.heap.page_allocator.alloc(u8, encoder.calcSize(bytes.len));
    defer std.heap.page_allocator.free(encoded);
    _ = encoder.encode(encoded, bytes);
    try util_json.writeJsonString(writer, encoded);
}

fn detectMediaType(bytes: []const u8) MediaType {
    if (isJson(bytes)) return .json;
    if (isInlineUtf8(bytes)) return .text_utf8;
    return .binary;
}

fn isJson(bytes: []const u8) bool {
    var scanner = std.json.Scanner.initCompleteInput(std.heap.page_allocator, bytes);
    defer scanner.deinit();
    while (true) {
        const token = scanner.next() catch return false;
        if (token == .end_of_document) return true;
    }
}

fn isInlineUtf8(bytes: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(bytes)) return false;
    for (bytes) |byte| {
        if (byte < 0x20 and byte != '\n' and byte != '\r' and byte != '\t') return false;
    }
    return true;
}

test "ToolResultBody promotes inline bytes to one recoverable artifact envelope" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    var body = ToolResultBody.initInline(try allocator.dupe(u8, "head-streamed-body-tail"));
    defer body.deinit(allocator);
    try std.testing.expect(try body.promoteInline(allocator, root));
    // Promoted = sealed (#73): the envelope is renderable now, the blob lands
    // when the batch commits.
    try std.testing.expect(body == .sealed);
    var rendered = try body.render(allocator);
    defer rendered.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, rendered.bytes, ENVELOPE_PREFIX ++ "\"artifact\""));
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes, "ReadArtifact") != null);
}

test "sealed body renders the same envelope as the published artifact" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &b);
    const root = b[0..n];
    const bytes: [3000]u8 = [_]u8{'x'} ** 3000;
    var s = try artifact_store.Spool.begin(a, root);
    try s.write(&bytes);
    const sealed = try s.seal();
    s.deinit();
    var body = ToolResultBody{ .sealed = .{ .spool = sealed, .media_type = .text_utf8, .capture_complete = true } };
    var r1 = try body.render(a);
    defer r1.deinit(a);
    body.deinit(a);
    var s2 = try artifact_store.Spool.begin(a, root);
    defer s2.deinit();
    try s2.write(&bytes);
    var c = try s2.finish();
    c.receipt.capture_complete = true;
    var body2 = ToolResultBody.fromCompletedSpool(c, .text_utf8);
    defer body2.deinit(a);
    var r2 = try body2.render(a);
    defer r2.deinit(a);
    try std.testing.expectEqualStrings(r1.bytes, r2.bytes);
}

test "takeModelBytes publishes a sealed body" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &b);
    const root = b[0..n];
    const bytes: [3000]u8 = [_]u8{'x'} ** 3000;
    var s = try artifact_store.Spool.begin(a, root);
    try s.write(&bytes);
    const sealed = try s.seal();
    s.deinit();
    var body = ToolResultBody{ .sealed = .{ .spool = sealed, .media_type = .text_utf8, .capture_complete = true } };
    const receipt = sealed.receipt();
    const taken = try body.takeModelBytes(a);
    defer a.free(taken.bytes);
    try std.testing.expect(std.mem.startsWith(u8, taken.bytes, ENVELOPE_PREFIX ++ "\"artifact\""));
    var chunk = try artifact_store.readChunk(a, root, receipt.id(), 0, 3000);
    defer chunk.deinit();
    try std.testing.expectEqualSlices(u8, &bytes, chunk.bytes);
}

test "StructuredToolError rejects invalid and over-budget payloads" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidStructuredToolError, StructuredToolError.init(allocator, "not-json"));
    try std.testing.expectError(error.InvalidStructuredToolError, StructuredToolError.init(allocator, "42"));
    try std.testing.expectError(error.InvalidStructuredToolError, StructuredToolError.init(allocator, "{\"value\":42}"));
    try std.testing.expectError(error.InvalidStructuredToolError, StructuredToolError.init(allocator, "{\"error\":\"plain\"}"));
    const valid = try StructuredToolError.init(allocator, "{\"error\":{\"code\":\"fixture\"}}");
    defer allocator.free(valid.encoded);
    const oversized = try allocator.alloc(u8, MAX_STRUCTURED_ERROR_BYTES + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.StructuredToolErrorTooLarge, StructuredToolError.init(allocator, oversized));
}

test "StructuredToolError maps known categories and ignores unknown categories" {
    const allocator = std.testing.allocator;
    const system_error = try StructuredToolError.init(
        allocator,
        "{\"error\":{\"category\":\"system_error\"}}",
    );
    defer allocator.free(system_error.encoded);
    try std.testing.expectEqual(
        @as(?tool_error.Category, .system_error),
        system_error.category,
    );

    const unknown = try StructuredToolError.init(
        allocator,
        "{\"error\":{\"category\":\"future_category\"}}",
    );
    defer allocator.free(unknown.encoded);
    try std.testing.expectEqual(@as(?tool_error.Category, null), unknown.category);
}

test "deinit after takeSealed is a no-op" {
    // `executeOne` releases the body after moving the handle out, so the
    // moved-out body must not touch the handle's temp file or leak.
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &b);
    const root = b[0..n];
    var s = try artifact_store.Spool.begin(a, root);
    defer s.deinit();
    try s.write("taken");
    const sealed = try s.seal();
    var body = ToolResultBody{ .sealed = .{ .spool = sealed, .media_type = .text_utf8, .capture_complete = true } };
    var handle = body.takeSealed() orelse return error.NothingTaken;
    body.deinit(a);
    // The handle still owns a readable temp file: deinit did not discard it.
    const bytes = try handle.spool.readAllAlloc(a);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("taken", bytes);
    handle.spool.deinit();
}

// ── #73: attachments of an inline body ───────────────────────────────────────

fn testSealedAttachment(allocator: std.mem.Allocator, root: []const u8, label: []const u8, payload: []const u8) !SealedArtifact {
    var spool = try artifact_store.Spool.begin(allocator, root);
    defer spool.deinit();
    try spool.write(payload);
    return .{ .spool = try spool.seal(), .media_type = .text_utf8, .capture_complete = true, .attachment_label = label };
}

test "withdrawAttachmentFromJson rewrites both id sites of one channel and nothing else" {
    const a = std.testing.allocator;
    const id = "sha256:" ++ ("a" ** 64);
    const body = "{\"schema_version\":\"metacodes.bash-result.v2\",\"stdout\":\"x\",\"stdout_artifact_id\":\"" ++ id ++
        "\",\"stdout_recoverable\":true,\"stdout_read\":{\"tool\":\"ReadArtifact\",\"artifact_id\":\"" ++ id ++
        "\",\"offset\":0,\"limit_max\":32768},\"stderr\":\"\",\"stderr_artifact_id\":null,\"stderr_recoverable\":true,\"exit_code\":0}";
    const out = try withdrawAttachmentFromJson(a, body, "stdout", id, "session_quota_exceeded");
    defer a.free(out);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":\"metacodes.bash-result.v2\",\"stdout\":\"x\",\"stdout_artifact_id\":null,\"stdout_storage_error\":\"session_quota_exceeded\"" ++
            ",\"stdout_recoverable\":false,\"stderr\":\"\",\"stderr_artifact_id\":null,\"stderr_recoverable\":true,\"exit_code\":0}",
        out,
    );
    // Still JSON after the surgery.
    var parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("stdout_artifact_id").? == .null);
    // A body without that channel's id is copied unchanged.
    const untouched = try withdrawAttachmentFromJson(a, "{\"stderr_artifact_id\":null}", "stdout", id, "x");
    defer a.free(untouched);
    try std.testing.expectEqualStrings("{\"stderr_artifact_id\":null}", untouched);
}

test "SealedHandles holds two attachments, refuses a third, and takeSealedHandles empties the body" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &b);
    const root = b[0..n];
    var body = ToolResultBody.initInline(try a.dupe(u8, "{}"));
    defer body.deinit(a);
    try body.@"inline".attachments.append(try testSealedAttachment(a, root, "stdout", "out-bytes"));
    try body.@"inline".attachments.append(try testSealedAttachment(a, root, "stderr", "err-bytes"));
    var third = try testSealedAttachment(a, root, "extra", "x");
    defer third.spool.deinit();
    try std.testing.expectError(error.TooManySealedHandles, body.@"inline".attachments.append(third));
    third.spool.discard();
    var handles = body.takeSealedHandles();
    defer handles.discard();
    try std.testing.expectEqual(@as(u8, 2), handles.len);
    try std.testing.expect(body.@"inline".attachments.isEmpty());
    try std.testing.expectEqualStrings("stdout", handles.items[0].?.attachment_label.?);
    // The body's own bytes survive the take; only the handles moved.
    try std.testing.expectEqualStrings("{}", body.@"inline".bytes);
}

test "resolveAttachments publishes what it can and withdraws what it cannot" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &b);
    const root = b[0..n];
    var handles = SealedHandles{};
    try handles.append(try testSealedAttachment(a, root, "stdout", "out-bytes"));
    try handles.append(try testSealedAttachment(a, root, "stderr", "err-bytes"));
    const out_id = try a.dupe(u8, handles.items[0].?.spool.receipt().id());
    defer a.free(out_id);
    const err_id = try a.dupe(u8, handles.items[1].?.spool.receipt().id());
    defer a.free(err_id);
    // A discarded handle cannot publish: that is the failure the loop meets at the commit boundary.
    handles.items[1].?.spool.discard();
    const body = try std.fmt.allocPrint(a, "{{\"stdout_artifact_id\":\"{s}\",\"stdout_recoverable\":true,\"stdout_read\":{{\"tool\":\"ReadArtifact\",\"artifact_id\":\"{s}\",\"offset\":0,\"limit_max\":32768}},\"stderr_artifact_id\":\"{s}\",\"stderr_recoverable\":true,\"stderr_read\":{{\"tool\":\"ReadArtifact\",\"artifact_id\":\"{s}\",\"offset\":0,\"limit_max\":32768}}}}", .{ out_id, out_id, err_id, err_id });
    const resolved = try resolveAttachments(a, body, &handles);
    defer a.free(resolved);
    try std.testing.expect(handles.isEmpty());
    try std.testing.expect(std.mem.indexOf(u8, resolved, out_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved, err_id) == null);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "\"stderr_artifact_id\":null,\"stderr_storage_error\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "\"stderr_recoverable\":false") != null);
    var chunk = try artifact_store.readChunk(a, root, out_id, 0, 9);
    defer chunk.deinit();
    try std.testing.expectEqualStrings("out-bytes", chunk.bytes);
}
