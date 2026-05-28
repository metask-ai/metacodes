//! NotebookEdit:修改 Jupyter notebook(.ipynb)cell。
//!
//! Schema:
//!   notebook_path:  必填,绝对路径
//!   new_source:     必填,新 cell 源代码
//!   cell_id:        可选;replace/delete 时定位目标;insert 时:在它后面插
//!                   insert 无 cell_id → 插入到 notebook 开头
//!   cell_type:      可选,"code" / "markdown";insert 必填
//!   edit_mode:      可选,"replace"(默认) / "insert" / "delete"
//!
//! 行为(对齐 Claude Code):
//!   - replace:覆盖 target cell 的 source(cell_type 可改)
//!   - insert:在 target cell 之后插入新 cell;cell_id 缺失 → 插入到开头
//!   - delete:删除 target cell(cell_id 必填)
//!
//! 实现:用 std.json 反/序列化,操作 cells 数组,回写。
//! 不做 must-read-first(notebook 通常不大,Read 单独读 cells)。

const std = @import("std");
const common = @import("common.zig");
const security = @import("security.zig");
const ToolContext = @import("context.zig").ToolContext;
const util_json = @import("../util/json.zig");

const EditMode = enum { replace, insert, delete };

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const a = ctx.allocator;
    const path = common.extractJsonArg(args, "notebook_path") orelse return error.MissingNotebookPath;
    if (path.len == 0) return error.EmptyNotebookPath;
    try security.validateNoTraversal(path);
    if (!std.mem.endsWith(u8, path, ".ipynb")) return error.NotANotebook;

    const new_source_raw = common.extractJsonArg(args, "new_source") orelse "";
    const new_source = try util_json.unescapeString(new_source_raw, a);
    defer a.free(new_source);

    const cell_id = common.extractJsonArg(args, "cell_id"); // optional
    const cell_type = common.extractJsonArg(args, "cell_type") orelse "code";
    if (!std.mem.eql(u8, cell_type, "code") and !std.mem.eql(u8, cell_type, "markdown")) {
        return error.InvalidCellType;
    }

    const edit_mode_str = common.extractJsonArg(args, "edit_mode") orelse "replace";
    const mode: EditMode = if (std.mem.eql(u8, edit_mode_str, "replace"))
        .replace
    else if (std.mem.eql(u8, edit_mode_str, "insert"))
        .insert
    else if (std.mem.eql(u8, edit_mode_str, "delete"))
        .delete
    else
        return error.InvalidEditMode;

    if ((mode == .replace or mode == .delete) and (cell_id == null or cell_id.?.len == 0)) {
        return error.MissingCellId;
    }

    // 读 notebook
    const content = try readFile(a, path);
    defer a.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, a, content, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidNotebook;
    // 取 cells 字段的可变指针(直接改 parent 内的 ArrayList)
    const cells_ptr = root.object.getPtr("cells") orelse return error.MissingCellsField;
    if (cells_ptr.* != .array) return error.InvalidCellsField;
    var cells_list = &cells_ptr.array; // ArrayList Managed

    // 操作 cells
    switch (mode) {
        .replace => {
            const idx = findCellById(cells_list.items, cell_id.?) orelse return error.CellNotFound;
            try setCellSource(parsed.arena.allocator(), &cells_list.items[idx], new_source);
            if (common.extractJsonArg(args, "cell_type")) |_| {
                try cells_list.items[idx].object.put(parsed.arena.allocator(), "cell_type", .{ .string = cell_type });
            }
        },
        .insert => {
            const new_cell = try buildNewCell(parsed.arena.allocator(), cell_type, new_source);
            if (cell_id) |cid| {
                const idx = findCellById(cells_list.items, cid) orelse return error.CellNotFound;
                try cells_list.insert(idx + 1, new_cell);
            } else {
                try cells_list.insert(0, new_cell);
            }
        },
        .delete => {
            const idx = findCellById(cells_list.items, cell_id.?) orelse return error.CellNotFound;
            _ = cells_list.orderedRemove(idx);
        },
    }

    // 写回
    const out_json = try serializeNotebook(a, root);
    defer a.free(out_json);
    try writeFile(path, out_json);

    return try std.fmt.allocPrint(a,
        "{{\"success\":true,\"path\":\"{s}\",\"mode\":\"{s}\",\"cells_after\":{d}}}",
        .{ path, edit_mode_str, cells_list.items.len },
    );
}

fn findCellById(cells: []const std.json.Value, id: []const u8) ?usize {
    for (cells, 0..) |c, i| {
        if (c != .object) continue;
        const cid_v = c.object.get("id") orelse continue;
        if (cid_v != .string) continue;
        if (std.mem.eql(u8, cid_v.string, id)) return i;
    }
    return null;
}

/// 设置 cell.source 字段。Jupyter `source` 可以是 string 或 array of strings;
/// 我们统一写成 string(单元素),Jupyter 读时兼容。
fn setCellSource(allocator: std.mem.Allocator, cell: *std.json.Value, source: []const u8) !void {
    if (cell.* != .object) return error.InvalidCell;
    try cell.object.put(allocator, "source", .{ .string = source });
}

fn buildNewCell(allocator: std.mem.Allocator, cell_type: []const u8, source: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "cell_type", .{ .string = try allocator.dupe(u8, cell_type) });
    const meta_obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "metadata", .{ .object = meta_obj });
    try obj.put(allocator, "source", .{ .string = try allocator.dupe(u8, source) });
    var id_buf: [16]u8 = undefined;
    const ns = @import("../util/time.zig").nowNs();
    const id = try std.fmt.bufPrint(&id_buf, "new-{x}", .{@as(u32, @truncate(@as(u128, @intCast(ns))))});
    try obj.put(allocator, "id", .{ .string = try allocator.dupe(u8, id) });
    if (std.mem.eql(u8, cell_type, "code")) {
        try obj.put(allocator, "execution_count", .{ .null = {} });
        try obj.put(allocator, "outputs", .{ .array = std.json.Array.init(allocator) });
    }
    return .{ .object = obj };
}

fn serializeNotebook(allocator: std.mem.Allocator, root: std.json.Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &aw.writer);
    return try aw.toOwnedSlice();
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer _ = std.c.close(fd);
    var buf: [65536]u8 = undefined;
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    while (true) {
        const n = std.posix.read(fd, &buf) catch return error.ReadError;
        if (n == 0) break;
        try result.appendSlice(allocator, buf[0..@as(usize, @intCast(n))]);
    }
    return try result.toOwnedSlice(allocator);
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch return error.WriteError;
    defer _ = std.c.close(fd);
    var pos: usize = 0;
    while (pos < content.len) {
        const n = std.c.write(fd, content.ptr + pos, content.len - pos);
        if (n <= 0) return error.WriteError;
        pos += @intCast(n);
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const SAMPLE_NB =
    \\{
    \\  "cells": [
    \\    {"cell_type":"code","id":"c1","metadata":{},"source":"x = 1","outputs":[],"execution_count":null},
    \\    {"cell_type":"markdown","id":"m1","metadata":{},"source":"## Title"}
    \\  ],
    \\  "metadata":{"language_info":{"name":"python"}},
    \\  "nbformat":4,"nbformat_minor":5
    \\}
;

fn writeNb(path: []const u8, body: []const u8) !void {
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    const fd = std.c.open(path_z, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = std.c.write(fd, body.ptr, body.len);
    _ = std.c.close(fd);
}

test "NotebookEdit: missing path" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.MissingNotebookPath, execute(&ctx, "{\"new_source\":\"y\"}"));
}

test "NotebookEdit: not .ipynb errors" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.NotANotebook, execute(&ctx, "{\"notebook_path\":\"/tmp/foo.txt\",\"new_source\":\"y\"}"));
}

test "NotebookEdit: invalid edit_mode" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.InvalidEditMode, execute(&ctx, "{\"notebook_path\":\"/tmp/x.ipynb\",\"new_source\":\"y\",\"edit_mode\":\"bogus\"}"));
}

test "NotebookEdit: replace cell source" {
    const a = testing.allocator;
    const p = "/tmp/cc-zig-nbedit-replace.ipynb";
    defer _ = std.c.unlink(p);
    try writeNb(p, SAMPLE_NB);

    const ctx = ToolContext.simple(a);
    const out = try execute(&ctx, "{\"notebook_path\":\"/tmp/cc-zig-nbedit-replace.ipynb\",\"cell_id\":\"c1\",\"new_source\":\"x = 42\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"success\":true") != null);

    // 验证文件含 x = 42
    const content = try readFile(a, p);
    defer a.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "x = 42") != null);
    try testing.expect(std.mem.indexOf(u8, content, "x = 1") == null);
}

test "NotebookEdit: insert cell at start" {
    const a = testing.allocator;
    const p = "/tmp/cc-zig-nbedit-insert-start.ipynb";
    defer _ = std.c.unlink(p);
    try writeNb(p, SAMPLE_NB);

    const ctx = ToolContext.simple(a);
    const out = try execute(&ctx,
        "{\"notebook_path\":\"/tmp/cc-zig-nbedit-insert-start.ipynb\",\"edit_mode\":\"insert\",\"new_source\":\"import numpy as np\",\"cell_type\":\"code\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"cells_after\":3") != null);

    const content = try readFile(a, p);
    defer a.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "numpy") != null);
}

test "NotebookEdit: insert cell after cell_id" {
    const a = testing.allocator;
    const p = "/tmp/cc-zig-nbedit-insert-after.ipynb";
    defer _ = std.c.unlink(p);
    try writeNb(p, SAMPLE_NB);

    const ctx = ToolContext.simple(a);
    const out = try execute(&ctx,
        "{\"notebook_path\":\"/tmp/cc-zig-nbedit-insert-after.ipynb\",\"cell_id\":\"c1\",\"edit_mode\":\"insert\",\"new_source\":\"y = 2\",\"cell_type\":\"code\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"cells_after\":3") != null);
}

test "NotebookEdit: delete cell" {
    const a = testing.allocator;
    const p = "/tmp/cc-zig-nbedit-delete.ipynb";
    defer _ = std.c.unlink(p);
    try writeNb(p, SAMPLE_NB);

    const ctx = ToolContext.simple(a);
    const out = try execute(&ctx,
        "{\"notebook_path\":\"/tmp/cc-zig-nbedit-delete.ipynb\",\"cell_id\":\"m1\",\"edit_mode\":\"delete\",\"new_source\":\"\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"cells_after\":1") != null);

    const content = try readFile(a, p);
    defer a.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "## Title") == null);
    try testing.expect(std.mem.indexOf(u8, content, "x = 1") != null);
}

test "NotebookEdit: cell_id not found errors" {
    const a = testing.allocator;
    const p = "/tmp/cc-zig-nbedit-notfound.ipynb";
    defer _ = std.c.unlink(p);
    try writeNb(p, SAMPLE_NB);

    const ctx = ToolContext.simple(a);
    try testing.expectError(error.CellNotFound, execute(&ctx,
        "{\"notebook_path\":\"/tmp/cc-zig-nbedit-notfound.ipynb\",\"cell_id\":\"nope\",\"new_source\":\"y\"}"));
}
