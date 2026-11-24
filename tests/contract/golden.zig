const std = @import("std");

pub const Mode = enum { check, update };

pub const update_hint = "zig build test:contract -Dupdate-contract";

pub const Store = struct {
    io: std.Io,
    root: []const u8,
    mode: Mode,

    pub fn expect(store: Store, gpa: std.mem.Allocator, rel_path: []const u8, actual: []const u8) !void {
        const path = try std.fs.path.join(gpa, &.{ store.root, rel_path });
        defer gpa.free(path);
        switch (store.mode) {
            .update => {
                if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(store.io, parent);
                try std.Io.Dir.cwd().writeFile(store.io, .{ .sub_path = path, .data = actual });
            },
            .check => {
                const expected = std.Io.Dir.cwd().readFileAlloc(store.io, path, gpa, .limited(64 << 20)) catch |err| switch (err) {
                    error.FileNotFound => {
                        std.debug.print("contract snapshot missing: tests/contract/{s}\nrecord it with: {s}\n", .{ rel_path, update_hint });
                        return error.ContractSnapshotMissing;
                    },
                    else => return err,
                };
                defer gpa.free(expected);
                if (std.mem.eql(u8, expected, actual)) return;
                const report = try describe(gpa, rel_path, expected, actual);
                defer gpa.free(report);
                std.debug.print("{s}", .{report});
                return error.ContractDrift;
            },
        }
    }
};

const max_hunks = 8;
const max_hunk_lines = 40;
const max_line_bytes = 300;
const resync_window = 400;
const resync_run = 3;

fn splitLines(gpa: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(gpa, line);
    return lines.toOwnedSlice(gpa);
}

fn matchesAt(e: []const []const u8, a: []const []const u8, i: usize, j: usize) bool {
    for (0..resync_run) |k| {
        if (i + k == e.len and j + k == a.len) return true;
        if (i + k >= e.len or j + k >= a.len) return false;
        if (!std.mem.eql(u8, e[i + k], a[j + k])) return false;
    }
    return true;
}

fn resync(e: []const []const u8, a: []const []const u8, i: usize, j: usize) [2]usize {
    var distance: usize = 1;
    while (distance <= 2 * resync_window) : (distance += 1) {
        for (0..distance + 1) |removed| {
            const added = distance - removed;
            if (i + removed > e.len or j + added > a.len) continue;
            if (matchesAt(e, a, i + removed, j + added)) return .{ removed, added };
        }
    }
    return .{ e.len - i, a.len - j };
}

pub fn describe(gpa: std.mem.Allocator, rel_path: []const u8, expected: []const u8, actual: []const u8) ![]u8 {
    const e = try splitLines(gpa, expected);
    defer gpa.free(e);
    const a = try splitLines(gpa, actual);
    defer gpa.free(a);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "contract drift: tests/contract/{s}\n", .{rel_path});
    var i: usize = 0;
    var j: usize = 0;
    var hunks: usize = 0;
    while (i < e.len or j < a.len) {
        if (i < e.len and j < a.len and std.mem.eql(u8, e[i], a[j])) {
            i += 1;
            j += 1;
            continue;
        }
        const removed, const added = resync(e, a, i, j);
        const column = if (removed > 0 and added > 0)
            std.mem.indexOfDiff(u8, e[i], a[j]) orelse @min(e[i].len, a[j].len)
        else
            0;
        if (hunks == 0) try out.print(gpa, "first difference: line {d}, column {d}\n", .{ i + 1, column + 1 });
        if (hunks < max_hunks) {
            try out.print(gpa, "@@ -{d},{d} +{d},{d} @@\n", .{ i + 1, removed, j + 1, added });
            if (i > 0) try printLine(gpa, &out, ' ', e[i - 1], column);
            try printLines(gpa, &out, '-', e[i .. i + removed], column);
            try printLines(gpa, &out, '+', a[j .. j + added], column);
            if (i + removed < e.len) try printLine(gpa, &out, ' ', e[i + removed], column);
        }
        hunks += 1;
        i += removed;
        j += added;
    }
    if (hunks > max_hunks) try out.print(gpa, "... {d} more changed regions\n", .{hunks - max_hunks});
    try out.print(gpa, "if this change is intended, record it with: {s}\n", .{update_hint});
    return out.toOwnedSlice(gpa);
}

fn printLines(gpa: std.mem.Allocator, out: *std.ArrayList(u8), mark: u8, lines: []const []const u8, column: usize) !void {
    for (lines[0..@min(lines.len, max_hunk_lines)]) |line| try printLine(gpa, out, mark, line, column);
    if (lines.len > max_hunk_lines) try out.print(gpa, "{c} ... {d} more lines\n", .{ mark, lines.len - max_hunk_lines });
}

fn printLine(gpa: std.mem.Allocator, out: *std.ArrayList(u8), mark: u8, line: []const u8, column: usize) !void {
    if (line.len <= max_line_bytes) return out.print(gpa, "{c}{s}\n", .{ mark, line });
    const start = @min(column -| max_line_bytes / 3, line.len - max_line_bytes);
    const lead: []const u8 = if (start > 0) "..." else "";
    try out.print(gpa, "{c}{s}{s} ... ({d} bytes, from byte {d})\n", .{ mark, lead, line[start..][0..max_line_bytes], line.len, start + 1 });
}
