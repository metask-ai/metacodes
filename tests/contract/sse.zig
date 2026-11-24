const std = @import("std");

pub const Response = struct {
    head: []const u8,
    frames: []const []const u8,
};

pub fn parse(a: std.mem.Allocator, raw: []const u8) !Response {
    const split = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.MissingResponseHead;
    var frames: std.ArrayList([]const u8) = .empty;
    var rest = raw[split + 4 ..];
    while (rest.len > 0) {
        const end = std.mem.indexOf(u8, rest, "\n\n") orelse return error.UnterminatedFrame;
        const frame = rest[0..end];
        rest = rest[end + 2 ..];
        if (isComment(frame)) continue;
        try frames.append(a, frame);
    }
    return .{ .head = raw[0..split], .frames = frames.items };
}

fn isComment(frame: []const u8) bool {
    var lines = std.mem.splitScalar(u8, frame, '\n');
    while (lines.next()) |line| if (!std.mem.startsWith(u8, line, ":")) return false;
    return true;
}

pub fn data(frame: []const u8) !?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, frame, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        if (found != null) return error.FrameCarriesSeveralLines;
        const value = line["data:".len..];
        found = if (std.mem.startsWith(u8, value, " ")) value[1..] else value;
    }
    return found;
}

pub fn render(a: std.mem.Allocator, response: Response) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var head = std.mem.splitSequence(u8, response.head, "\r\n");
    while (head.next()) |line| try out.print(a, "{s}\n", .{line});
    try out.append(a, '\n');
    for (response.frames) |frame| try out.print(a, "{s}\n\n", .{frame});
    return out.items;
}

pub fn journal(a: std.mem.Allocator, response: Response) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (response.frames) |frame| {
        const payload = try data(frame) orelse continue;
        try out.print(a, "{s}\n", .{payload});
    }
    return out.items;
}
