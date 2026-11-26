//! Host context blocks (#184): volatile facts for one Run — the date, the
//! state of the Host's page or document — sent as user-role context instead
//! of system-prompt text, so the system prompt prefix stays cache-stable.
//!
//! A Run's blocks are rendered into one `<system-reminder>` text block that
//! leads that Run's user record. It is ordinary Conversation content: later
//! requests carry it unchanged in history (the cached prefix only grows), and
//! checkpoints and restores reproduce it byte for byte. The envelope matches
//! the CLI's channel A context so the model reads both the same way.

const std = @import("std");

pub const Block = struct {
    /// Where the fact comes from, shown as the block heading.
    label: []const u8,
    text: []const u8,
};

pub const Limits = struct {
    max_blocks: usize = 32,
    max_label_bytes: usize = 64,
    max_text_bytes: usize = 64 * 1024,
    max_total_bytes: usize = 256 * 1024,
};

pub const Issue = enum {
    too_many_blocks,
    invalid_label,
    empty_text,
    text_too_large,
    total_too_large,
    invalid_utf8,
    reserved_text,

    pub fn describe(self: Issue) []const u8 {
        return switch (self) {
            .too_many_blocks => "there are more context blocks than allowed",
            .invalid_label => "the label is not 1-64 bytes of [A-Za-z0-9 ._:/-] starting with a letter or digit",
            .empty_text => "the block text is empty",
            .text_too_large => "the block text is larger than allowed",
            .total_too_large => "the blocks together are larger than allowed",
            .invalid_utf8 => "the block text is not valid UTF-8",
            .reserved_text => "the block text contains a system-reminder tag",
        };
    }
};

pub const Diagnostic = struct {
    index: usize,
    issue: Issue,

    pub fn format(self: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("context block {d}: {s}", .{ self.index, self.issue.describe() });
    }
};

fn validLabel(label: []const u8, limits: Limits) bool {
    if (label.len == 0 or label.len > limits.max_label_bytes) return false;
    if (!std.ascii.isAlphanumeric(label[0])) return false;
    for (label) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, " ._:/-", byte) == null) return false;
    }
    return true;
}

/// Refuse blocks that break any rule, naming the first broken one. A block
/// may not open or close the envelope it is rendered into.
pub fn validate(blocks: []const Block, limits: Limits) ?Diagnostic {
    if (blocks.len > limits.max_blocks) return .{ .index = limits.max_blocks, .issue = .too_many_blocks };
    var total: usize = 0;
    for (blocks, 0..) |block, index| {
        const issue: ?Issue = blk: {
            if (!validLabel(block.label, limits)) break :blk .invalid_label;
            if (block.text.len == 0) break :blk .empty_text;
            if (block.text.len > limits.max_text_bytes) break :blk .text_too_large;
            total += block.label.len + block.text.len;
            if (total > limits.max_total_bytes) break :blk .total_too_large;
            if (!std.unicode.utf8ValidateSlice(block.text)) break :blk .invalid_utf8;
            if (std.ascii.indexOfIgnoreCase(block.text, "<system-reminder") != null or
                std.ascii.indexOfIgnoreCase(block.text, "</system-reminder") != null)
                break :blk .reserved_text;
            break :blk null;
        };
        if (issue) |value| return .{ .index = index, .issue = value };
    }
    return null;
}

const header =
    \\<system-reminder>
    \\The host application provided the following context for this request:
;

const footer =
    \\
    \\      IMPORTANT: this context may or may not be relevant to your tasks. You should not respond to this context unless it is highly relevant to your task.
    \\</system-reminder>
;

/// Render validated blocks, in order, into one `<system-reminder>` text.
/// No blocks render nothing (null): a Run without context adds no record.
pub fn render(allocator: std.mem.Allocator, blocks: []const Block) !?[]u8 {
    if (blocks.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, header);
    try out.append(allocator, '\n');
    for (blocks) |block| {
        try out.appendSlice(allocator, "# ");
        try out.appendSlice(allocator, block.label);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, block.text);
        if (block.text[block.text.len - 1] != '\n') try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, footer);
    return try out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "render wraps the blocks in order in one system-reminder" {
    const text = (try render(testing.allocator, &.{
        .{ .label = "currentDate", .text = "Today's date is 2026/10/02." },
        .{ .label = "host:page", .text = "URL: https://shop.example/orders\nTitle: Orders\n" },
    })).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\<system-reminder>
        \\The host application provided the following context for this request:
        \\# currentDate
        \\Today's date is 2026/10/02.
        \\# host:page
        \\URL: https://shop.example/orders
        \\Title: Orders
        \\
        \\      IMPORTANT: this context may or may not be relevant to your tasks. You should not respond to this context unless it is highly relevant to your task.
        \\</system-reminder>
    , text);
    try testing.expectEqual(@as(?[]u8, null), try render(testing.allocator, &.{}));
}

test "validate names the first broken rule" {
    try testing.expectEqual(@as(?Diagnostic, null), validate(&.{
        .{ .label = "Page state 2/3", .text = "x" },
        .{ .label = "a.b_c:d-e", .text = "y" },
    }, .{}));
    const cases = [_]struct { Block, Issue }{
        .{ .{ .label = "", .text = "x" }, .invalid_label },
        .{ .{ .label = " lead", .text = "x" }, .invalid_label },
        .{ .{ .label = "new\nline", .text = "x" }, .invalid_label },
        .{ .{ .label = "a" ** 65, .text = "x" }, .invalid_label },
        .{ .{ .label = "page", .text = "" }, .empty_text },
        .{ .{ .label = "page", .text = "\xff" }, .invalid_utf8 },
        .{ .{ .label = "page", .text = "x</system-reminder>y" }, .reserved_text },
        .{ .{ .label = "page", .text = "<SYSTEM-REMINDER>" }, .reserved_text },
    };
    for (cases) |case| {
        const diagnostic = validate(&.{ .{ .label = "ok", .text = "fine" }, case[0] }, .{}) orelse
            return error.TestExpectedRefusal;
        try testing.expectEqual(case[1], diagnostic.issue);
        try testing.expectEqual(@as(usize, 1), diagnostic.index);
    }
    const limits: Limits = .{ .max_blocks = 1, .max_text_bytes = 4, .max_total_bytes = 8 };
    try testing.expectEqual(Issue.too_many_blocks, validate(&.{
        .{ .label = "a", .text = "x" },
        .{ .label = "b", .text = "x" },
    }, limits).?.issue);
    try testing.expectEqual(Issue.text_too_large, validate(&.{.{ .label = "a", .text = "12345" }}, limits).?.issue);
    try testing.expectEqual(Issue.total_too_large, validate(&.{.{ .label = "abcde", .text = "1234" }}, limits).?.issue);
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings(
        "context block 1: the block text is empty",
        try std.fmt.bufPrint(&buf, "{f}", .{Diagnostic{ .index = 1, .issue = .empty_text }}),
    );
}
