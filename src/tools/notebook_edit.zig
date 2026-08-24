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
const pfs = @import("platform").fs;
const common = @import("common.zig");
const path_mod = @import("../util/path.zig");
const ToolContext = @import("context.zig").ToolContext;
const util_json = @import("../util/json.zig");

const EditMode = enum { replace, insert, delete };

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const a = ctx.allocator;
    const path_raw = common.extractJsonArg(args, "notebook_path") orelse return error.MissingNotebookPath;
    if (path_raw.len == 0) return error.EmptyNotebookPath;
    // 归一化(展开 ~、折叠、查 traversal)。openat 不认 ~。
    const path = try path_mod.normalizeChecked(a, path_raw, .{ .home = ctx.home_dir, .base_dir = ctx.cwd_abs });
    defer a.free(path);
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

    // 操作 cells。同时记录 old/new source(供 diff 展示 + hl-zig 高亮)。
    var old_src: []const u8 = "";
    var new_src: []const u8 = "";
    var is_markdown = std.mem.eql(u8, cell_type, "markdown");
    switch (mode) {
        .replace => {
            const idx = findCellById(cells_list.items, cell_id.?) orelse return error.CellNotFound;
            // 改前抓旧 source(供 diff);cell_type 未显式改时沿用原 cell 类型判 markdown。
            old_src = try cellSourceDup(a, cells_list.items[idx]);
            if (common.extractJsonArg(args, "cell_type") == null) {
                is_markdown = cellIsMarkdown(cells_list.items[idx]);
            }
            try setCellSource(parsed.arena.allocator(), &cells_list.items[idx], new_source);
            if (common.extractJsonArg(args, "cell_type")) |_| {
                try cells_list.items[idx].object.put(parsed.arena.allocator(), "cell_type", .{ .string = cell_type });
            }
            new_src = new_source;
        },
        .insert => {
            const new_cell = try buildNewCell(parsed.arena.allocator(), cell_type, new_source);
            if (cell_id) |cid| {
                const idx = findCellById(cells_list.items, cid) orelse return error.CellNotFound;
                try cells_list.insert(idx + 1, new_cell);
            } else {
                try cells_list.insert(0, new_cell);
            }
            new_src = new_source; // old="" → 纯新增(plain 展示)
        },
        .delete => {
            const idx = findCellById(cells_list.items, cell_id.?) orelse return error.CellNotFound;
            old_src = try cellSourceDup(a, cells_list.items[idx]); // new="" → 纯删除
            is_markdown = cellIsMarkdown(cells_list.items[idx]);
            _ = cells_list.orderedRemove(idx);
        },
    }
    defer if (old_src.len > 0) a.free(old_src);

    // 写回
    const out_json = try serializeNotebook(a, root);
    defer a.free(out_json);
    try writeFile(path, out_json);

    // cell 语言(供高亮):markdown cell 不高亮代码;code cell 用 notebook language_info.name(默认 python)。
    const lang: []const u8 = if (is_markdown) "" else notebookLang(root);

    // 旁路缓存 cell 新旧 source(供工具卡 hl-zig 高亮;不进对话历史)。
    if (ctx.edit_hl_cache) |cache| {
        cache.put(ctx.progress_tool_id, old_src, new_src);
    }

    // 产 gitDiff(供工具卡 diff 渲染)。失败则退回简单摘要(不阻断)。
    const patch_mod = @import("../core/patch.zig");
    const git_diff: ?[]u8 = blk: {
        var patch = patch_mod.compute(a, old_src, new_src) catch break :blk null;
        defer patch.deinit(a);
        break :blk patch_mod.toGitDiff(a, path, patch.hunks) catch null;
    };
    defer if (git_diff) |g| a.free(g);

    // 稳定文件修改契约:notebook 整文件被重写,diff 描述被改动的 cell(与工具卡展示同源)。
    // 无 diff(cell 内容算不出 patch)时明确标 incomplete,不让消费者把"没 diff"读成"没改"。
    ctx.reportFileChange(.{
        .path = path,
        .kind = .modified,
        .status = if (std.mem.eql(u8, content, out_json)) .no_change else .applied,
        .before_bytes = content.len,
        .after_bytes = out_json.len,
        .unified_diff = git_diff,
        .diff_complete = git_diff != null,
    });

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.print(
        "{{\"success\":true,\"path\":\"{s}\",\"mode\":\"{s}\",\"cells_after\":{d}",
        .{ path, edit_mode_str, cells_list.items.len },
    );
    if (lang.len > 0) {
        try out.writer.print(",\"lang\":\"{s}\"", .{lang});
    }
    if (git_diff) |g| {
        try out.writer.writeAll(",\"gitDiff\":");
        try std.json.Stringify.encodeJsonString(g, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

/// 读 cell.source(Jupyter 里可能是 string 或 array of strings),拼成单串(owned)。
fn cellSourceDup(allocator: std.mem.Allocator, cell: std.json.Value) ![]const u8 {
    if (cell != .object) return try allocator.dupe(u8, "");
    const src = cell.object.get("source") orelse return try allocator.dupe(u8, "");
    switch (src) {
        .string => |s| return try allocator.dupe(u8, s),
        .array => |arr| {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            for (arr.items) |item| {
                if (item == .string) try buf.appendSlice(allocator, item.string);
            }
            return try buf.toOwnedSlice(allocator);
        },
        else => return try allocator.dupe(u8, ""),
    }
}

fn cellIsMarkdown(cell: std.json.Value) bool {
    if (cell != .object) return false;
    const ct = cell.object.get("cell_type") orelse return false;
    return ct == .string and std.mem.eql(u8, ct.string, "markdown");
}

/// notebook 的 metadata.language_info.name(默认 "python")。
fn notebookLang(root: std.json.Value) []const u8 {
    if (root != .object) return "python";
    const meta = root.object.get("metadata") orelse return "python";
    if (meta != .object) return "python";
    const li = meta.object.get("language_info") orelse return "python";
    if (li != .object) return "python";
    const name = li.object.get("name") orelse return "python";
    if (name != .string or name.string.len == 0) return "python";
    return name.string;
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

/// notebook 整读上限(轴A):notebook 必须整读进内存解析 JSON(std.json 再翻倍),巨型必 OOM →
/// 超此值拒绝(readAllFromFdCapped 返 error.FileTooLarge)。50MB 对任何真实 notebook 都绰绰,只堵病态巨型。
const MAX_NOTEBOOK_SIZE: usize = 50 * 1024 * 1024;

/// 走轴A统一入口 readAllFromFdCapped(消除各工具本地裸读绕过守卫)。
fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer _ = pfs.close(fd);
    return try @import("common.zig").readAllFromFdCapped(fd, allocator, MAX_NOTEBOOK_SIZE);
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const fd = pfs.openZ(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch return error.WriteError;
    defer _ = pfs.close(fd);
    var pos: usize = 0;
    while (pos < content.len) {
        const n = pfs.write(fd, content[pos..][0 .. content.len - pos]);
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
    const fd = pfs.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = pfs.write(fd, body);
    _ = pfs.close(fd);
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
    const out = try execute(&ctx, "{\"notebook_path\":\"/tmp/cc-zig-nbedit-insert-start.ipynb\",\"edit_mode\":\"insert\",\"new_source\":\"import numpy as np\",\"cell_type\":\"code\"}");
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
    const out = try execute(&ctx, "{\"notebook_path\":\"/tmp/cc-zig-nbedit-insert-after.ipynb\",\"cell_id\":\"c1\",\"edit_mode\":\"insert\",\"new_source\":\"y = 2\",\"cell_type\":\"code\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"cells_after\":3") != null);
}

test "NotebookEdit: delete cell" {
    const a = testing.allocator;
    const p = "/tmp/cc-zig-nbedit-delete.ipynb";
    defer _ = std.c.unlink(p);
    try writeNb(p, SAMPLE_NB);

    const ctx = ToolContext.simple(a);
    const out = try execute(&ctx, "{\"notebook_path\":\"/tmp/cc-zig-nbedit-delete.ipynb\",\"cell_id\":\"m1\",\"edit_mode\":\"delete\",\"new_source\":\"\"}");
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
    try testing.expectError(error.CellNotFound, execute(&ctx, "{\"notebook_path\":\"/tmp/cc-zig-nbedit-notfound.ipynb\",\"cell_id\":\"nope\",\"new_source\":\"y\"}"));
}
