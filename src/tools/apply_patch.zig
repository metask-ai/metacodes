//! ApplyPatch 工具(P1.1):接收 codex 风格的 patch 信封,批量对多文件做新增/删除/修改/重命名。
//!
//! **格式**(codex 自定义信封,非标准 unified diff——无行号,靠 `@@` 上下文 + 前后行模糊定位,对
//! 模型更鲁棒。对齐 OpenAI/codex 模型训练的 apply_patch 格式):
//! ```
//! *** Begin Patch
//! *** Add File: hello.txt
//! +Hello world
//! *** Update File: src/app.py
//! *** Move to: src/main.py
//! @@ def greet():
//! -print("Hi")
//! +print("Hello")
//! *** Delete File: obsolete.txt
//! *** End Patch
//! ```
//! 四种操作:Add File(每行 `+`)/ Delete File / Update File(`@@` 上下文 + `-`/`+`/` ` 行)/
//! Update+Move to(重命名 + 可选修改)。一个 Update 可含多个 `@@` chunk。
//!
//! **定位**:`seek`(4 级降级:精确 → 忽略行尾空白 → 忽略首尾空白 → Unicode 标点/空格归一化)。
//! **应用两阶段**:
//!   - **phase 1(校验,事务性)**:内存里算出所有文件最终内容 + 校验所有 context/old_lines 定位得到、
//!     Add 目标不存在、Delete/Update 目标存在、所有路径过权限门。**任一失败 → 整批零落盘**。这是相对
//!     codex(非事务)的真价值:解析/定位/权限错误绝不留半成品。
//!   - **phase 2(落盘,非原子)**:校验全过后逐文件写入。**此阶段非原子、无回滚**——若中途 IO 失败
//!     (磁盘满/权限被并发改),已写文件保留,后续不再写。真正的 crash-safe 多文件原子提交(temp+rename+
//!     fsync)本实现不做(codex 亦不做)。绝大多数失败在 phase 1 被挡下;phase 2 失败罕见但可能留部分写入。
//!
//! **已知差距(未实现,登记非沉默)**:① codex `*** Environment ID:` 行(远程执行用)——遇到会报
//! InvalidHunkHeader;② heredoc lenient 包裹(`apply_patch <<'EOF'`)——invocation 层特性,JSON `patch`
//! 字段场景 N/A;③ 与 codex 的**故意语义分歧**:codex Add File 撞已存在文件会覆盖、失败后留部分改动,
//! 本实现 Add 撞已存在→报错、phase-1 失败→零落盘(更安全)。见 doc/E2E gap matrix。
//!
//! **复用**:path 归一化 / read_state 刷新 / patch.zig 的 gitDiff 生成 / edit_hl_cache(首文件高亮)。

const std = @import("std");
const pfs = @import("platform").fs;
const common = @import("common.zig");
const path_mod = @import("../util/path.zig");
const util_json = @import("../util/json.zig");
const read_state = @import("../core/read_state.zig");
const ToolContext = @import("context.zig").ToolContext;

const MAX_PATCH_FILE_SIZE: u64 = 1 << 30; // 1 GiB,与 Edit 一致

// ── 格式常量 ────────────────────────────────────────────────────────────────
const BEGIN_MARKER = "*** Begin Patch";
const END_MARKER = "*** End Patch";
const ADD_MARKER = "*** Add File: ";
const DELETE_MARKER = "*** Delete File: ";
const UPDATE_MARKER = "*** Update File: ";
const MOVE_MARKER = "*** Move to: ";
const EOF_MARKER = "*** End of File";
const CTX_MARKER = "@@ ";
const CTX_MARKER_EMPTY = "@@";

// ── 数据结构 ────────────────────────────────────────────────────────────────
const Chunk = struct {
    change_context: ?[]const u8 = null,
    old_lines: std.ArrayList([]const u8) = .empty,
    new_lines: std.ArrayList([]const u8) = .empty,
    is_end_of_file: bool = false,
};

const Hunk = union(enum) {
    add_file: struct { path: []const u8, contents: []const u8 },
    delete_file: struct { path: []const u8 },
    update_file: struct { path: []const u8, move_path: ?[]const u8, chunks: std.ArrayList(Chunk) },
};

pub const ParseError = error{
    MissingBeginMarker,
    MissingEndMarker,
    InvalidHunkHeader,
    EmptyUpdateHunk,
    UnexpectedLineInUpdateHunk,
    EmptyPatch,
    OutOfMemory,
};

// ============================================================================
// Parser:逐行状态机(全量输入版,非流式;结果等价 codex streaming_parser)
// ============================================================================

const ParseState = enum { not_started, started, add_file, delete_file, update_file, ended };

const Parser = struct {
    arena: std.mem.Allocator,
    hunks: std.ArrayList(Hunk) = .empty,
    state: ParseState = .not_started,

    fn parse(arena: std.mem.Allocator, patch_text: []const u8) ParseError!std.ArrayList(Hunk) {
        var p = Parser{ .arena = arena };
        // 剥首尾空白后按行切(每行去掉尾随 \r)。
        const trimmed = std.mem.trim(u8, patch_text, " \t\r\n");
        var lines = std.ArrayList([]const u8).empty;
        {
            var it = std.mem.splitScalar(u8, trimmed, '\n');
            while (it.next()) |ln| try lines.append(arena, std.mem.trimEnd(u8, ln, "\r"));
        }
        if (lines.items.len == 0) return error.EmptyPatch;

        for (lines.items) |line| {
            try p.processLine(line);
            if (p.state == .ended) break;
        }
        if (p.state == .not_started) return error.MissingBeginMarker;
        if (p.state != .ended) {
            // 允许无显式 End Patch 结尾(lenient):只要开过 patch 且末尾 hunk 合法即可。
            try p.finishOpenUpdate();
            if (p.state == .started) return error.EmptyPatch;
        }
        return p.hunks;
    }

    fn curUpdate(self: *Parser) *Hunk {
        return &self.hunks.items[self.hunks.items.len - 1];
    }

    /// Update hunk 收尾校验:非空 + 至少一个有效 chunk。
    fn finishOpenUpdate(self: *Parser) ParseError!void {
        if (self.state != .update_file) return;
        const h = self.curUpdate();
        if (h.update_file.chunks.items.len == 0) return error.EmptyUpdateHunk;
        for (h.update_file.chunks.items) |c| {
            if (c.old_lines.items.len == 0 and c.new_lines.items.len == 0) return error.EmptyUpdateHunk;
        }
    }

    fn processLine(self: *Parser, line: []const u8) ParseError!void {
        const trimmed = std.mem.trim(u8, line, " \t");
        switch (self.state) {
            .not_started => {
                if (std.mem.eql(u8, trimmed, BEGIN_MARKER)) {
                    self.state = .started;
                } else return error.MissingBeginMarker;
            },
            .started, .add_file, .delete_file, .update_file => {
                // 先看是否是新 hunk 头 / End Patch(会切换状态)。
                if (std.mem.eql(u8, trimmed, END_MARKER)) {
                    try self.finishOpenUpdate();
                    self.state = .ended;
                    return;
                }
                if (try self.tryHunkHeader(trimmed)) return;
                // 非头行:按当前状态消费内容行。
                switch (self.state) {
                    .add_file => try self.consumeAddLine(line),
                    .update_file => try self.consumeUpdateLine(line),
                    .delete_file => return error.UnexpectedLineInUpdateHunk, // delete 后不该有内容
                    .started => return error.InvalidHunkHeader, // Begin 后必须先来 hunk 头
                    else => unreachable,
                }
            },
            .ended => {}, // End Patch 之后忽略
        }
    }

    /// 尝试把 trimmed 当作 hunk 头解析。是 → 建新 hunk 并切状态,返 true;否则 false。
    fn tryHunkHeader(self: *Parser, trimmed: []const u8) ParseError!bool {
        if (std.mem.startsWith(u8, trimmed, ADD_MARKER)) {
            try self.finishOpenUpdate();
            const path = std.mem.trim(u8, trimmed[ADD_MARKER.len..], " \t");
            try self.hunks.append(self.arena, .{ .add_file = .{ .path = path, .contents = "" } });
            self.state = .add_file;
            return true;
        }
        if (std.mem.startsWith(u8, trimmed, DELETE_MARKER)) {
            try self.finishOpenUpdate();
            const path = std.mem.trim(u8, trimmed[DELETE_MARKER.len..], " \t");
            try self.hunks.append(self.arena, .{ .delete_file = .{ .path = path } });
            self.state = .delete_file;
            return true;
        }
        if (std.mem.startsWith(u8, trimmed, UPDATE_MARKER)) {
            try self.finishOpenUpdate();
            const path = std.mem.trim(u8, trimmed[UPDATE_MARKER.len..], " \t");
            try self.hunks.append(self.arena, .{ .update_file = .{ .path = path, .move_path = null, .chunks = .empty } });
            self.state = .update_file;
            return true;
        }
        return false;
    }

    fn consumeAddLine(self: *Parser, line: []const u8) ParseError!void {
        const h = self.curUpdate();
        if (line.len == 0 or line[0] != '+') return error.UnexpectedLineInUpdateHunk;
        // 追加 line[1..] + '\n' 到 contents(累积到 arena buffer)。
        const prev = h.add_file.contents;
        const add = line[1..];
        const buf = try self.arena.alloc(u8, prev.len + add.len + 1);
        @memcpy(buf[0..prev.len], prev);
        @memcpy(buf[prev.len .. prev.len + add.len], add);
        buf[buf.len - 1] = '\n';
        h.add_file.contents = buf;
    }

    fn consumeUpdateLine(self: *Parser, line: []const u8) ParseError!void {
        const h = self.curUpdate();
        const uf = &h.update_file;
        const trimmed_end = std.mem.trimEnd(u8, line, " \t");

        // Move to:(必须在任何 chunk 之前)。
        if (uf.chunks.items.len == 0 and uf.move_path == null and std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), MOVE_MARKER)) {
            const t = std.mem.trim(u8, line, " \t");
            uf.move_path = std.mem.trim(u8, t[MOVE_MARKER.len..], " \t");
            return;
        }
        // @@ 上下文头 → 新 chunk。
        if (std.mem.eql(u8, trimmed_end, CTX_MARKER_EMPTY)) {
            try uf.chunks.append(self.arena, .{});
            return;
        }
        if (std.mem.startsWith(u8, trimmed_end, CTX_MARKER)) {
            try uf.chunks.append(self.arena, .{ .change_context = std.mem.trim(u8, trimmed_end[CTX_MARKER.len..], " \t") });
            return;
        }
        // *** End of File 标记。
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), EOF_MARKER)) {
            if (uf.chunks.items.len > 0) uf.chunks.items[uf.chunks.items.len - 1].is_end_of_file = true;
            return;
        }
        // 内容行:` `(context)/`+`(add)/`-`(del)/空行(空 context)。无当前 chunk 则隐式建一个。
        if (uf.chunks.items.len == 0) try uf.chunks.append(self.arena, .{});
        const chunk = &uf.chunks.items[uf.chunks.items.len - 1];
        if (line.len == 0) {
            try chunk.old_lines.append(self.arena, "");
            try chunk.new_lines.append(self.arena, "");
            return;
        }
        switch (line[0]) {
            ' ' => {
                try chunk.old_lines.append(self.arena, line[1..]);
                try chunk.new_lines.append(self.arena, line[1..]);
            },
            '+' => try chunk.new_lines.append(self.arena, line[1..]),
            '-' => try chunk.old_lines.append(self.arena, line[1..]),
            else => return error.UnexpectedLineInUpdateHunk,
        }
    }
};

// ============================================================================
// Seek:context/old_lines 在文件行数组里的模糊定位(4 级降级,移植 seek_sequence.rs)
// ============================================================================

/// 从 start 起在 lines 里找 pattern 序列首次出现的下标。eof=true 时从末尾对齐开始搜。
/// 4 级降级:精确 → 忽略行尾空白 → 忽略首尾空白 → Unicode 标点/空格归一化后 trim。找不到 null。
fn seek(arena: std.mem.Allocator, lines: []const []const u8, pattern: []const []const u8, start: usize, eof: bool) ?usize {
    if (pattern.len == 0) return start;
    if (pattern.len > lines.len) return null;
    const begin = if (eof and lines.len >= pattern.len) lines.len - pattern.len else start;

    // Level 1: 精确。
    if (seekWith(lines, pattern, begin, eqExact, arena)) |i| return i;
    // Level 2: 忽略行尾空白。
    if (seekWith(lines, pattern, begin, eqRstrip, arena)) |i| return i;
    // Level 3: 忽略首尾空白。
    if (seekWith(lines, pattern, begin, eqTrim, arena)) |i| return i;
    // Level 4: Unicode 归一化 + trim。
    if (seekWith(lines, pattern, begin, eqUnicode, arena)) |i| return i;
    return null;
}

const EqFn = *const fn (a: []const u8, b: []const u8, arena: std.mem.Allocator) bool;

fn seekWith(lines: []const []const u8, pattern: []const []const u8, begin: usize, eqf: EqFn, arena: std.mem.Allocator) ?usize {
    if (pattern.len > lines.len) return null;
    var i = begin;
    const last = lines.len - pattern.len;
    while (i <= last) : (i += 1) {
        var all = true;
        for (pattern, 0..) |pl, j| {
            if (!eqf(lines[i + j], pl, arena)) {
                all = false;
                break;
            }
        }
        if (all) return i;
    }
    return null;
}

fn eqExact(a: []const u8, b: []const u8, _: std.mem.Allocator) bool {
    return std.mem.eql(u8, a, b);
}
fn eqRstrip(a: []const u8, b: []const u8, _: std.mem.Allocator) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, a, " \t"), std.mem.trimEnd(u8, b, " \t"));
}
fn eqTrim(a: []const u8, b: []const u8, _: std.mem.Allocator) bool {
    return std.mem.eql(u8, std.mem.trim(u8, a, " \t"), std.mem.trim(u8, b, " \t"));
}
fn eqUnicode(a: []const u8, b: []const u8, arena: std.mem.Allocator) bool {
    const na = normalizeUnicode(arena, a) catch return false;
    const nb = normalizeUnicode(arena, b) catch return false;
    return std.mem.eql(u8, std.mem.trim(u8, na, " \t"), std.mem.trim(u8, nb, " \t"));
}

/// Unicode 标点/空格归一化:各种破折号→`-`、花引号→`'`/`"`、奇异空格→普通空格。让 ASCII patch
/// 匹配含排版字符的源码(移植 seek_sequence.rs 的归一化表)。返回 arena owned。
fn normalizeUnicode(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    const view = std.unicode.Utf8View.init(s) catch {
        // 非法 UTF-8:原样返回(不归一化)。
        return arena.dupe(u8, s);
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const repl: ?u8 = switch (cp) {
            0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212 => '-', // 各类破折号/减号
            0x2018, 0x2019, 0x201B, 0x2032 => '\'', // 花单引号/prime
            0x201C, 0x201D, 0x201F, 0x2033 => '"', // 花双引号
            0x00A0, 0x2007, 0x202F, 0x2005, 0x2009, 0x200A, 0x2002, 0x2003 => ' ', // 各类空格
            else => null,
        };
        if (repl) |r| {
            try out.append(arena, r);
        } else {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch 0;
            try out.appendSlice(arena, buf[0..n]);
        }
    }
    return out.toOwnedSlice(arena);
}

// ============================================================================
// Applier:算出每个 Update 文件的新内容(纯内存,不落盘)
// ============================================================================

const ApplyError = error{
    ContextNotFound,
    OldLinesNotFound,
    OutOfMemory,
};

/// 把一个文件的所有 chunk 应用到 original,产出新内容(arena owned)。context 定位失败即报错。
fn deriveNewContents(arena: std.mem.Allocator, original: []const u8, chunks: []const Chunk, path: []const u8, detail: *?[]const u8) ApplyError![]u8 {
    // split '\n',去掉末尾因结尾换行产生的空元素。
    var lines = std.ArrayList([]const u8).empty;
    {
        var it = std.mem.splitScalar(u8, original, '\n');
        while (it.next()) |ln| try lines.append(arena, ln);
    }
    const had_trailing_nl = lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0;
    if (had_trailing_nl) _ = lines.pop();

    const Replacement = struct { start: usize, old_len: usize, new_lines: []const []const u8, order: usize };
    var repls = std.ArrayList(Replacement).empty;
    var order_ctr: usize = 0;

    var line_index: usize = 0;
    for (chunks) |chunk| {
        // change_context 先定位并前移 index(仅影响 old_lines 匹配起点;纯新增仍 append 到 EOF)。
        if (chunk.change_context) |ctx_str| {
            const pat = [_][]const u8{ctx_str};
            const idx = seek(arena, lines.items, &pat, line_index, false) orelse {
                detail.* = std.fmt.allocPrint(arena, "Failed to find context '{s}' in {s}", .{ ctx_str, path }) catch null;
                return error.ContextNotFound;
            };
            line_index = idx + 1;
        }
        if (chunk.old_lines.items.len == 0) {
            // 纯新增(无 old_lines):追加到**文件末尾**(对齐 codex compute_replacements)。
            // lines 已剥掉结尾换行产生的空元素,故 lines.items.len 即 EOF 插入点。
            try repls.append(arena, .{ .start = lines.items.len, .old_len = 0, .new_lines = chunk.new_lines.items, .order = order_ctr });
            order_ctr += 1;
            continue;
        }
        // 定位 old_lines。若首次失败且 pattern 末尾是空串(代表文件末尾换行,split 时被剥),
        // 去掉该末尾空串重试(对齐 codex:end-of-file 修改的可靠定位)。
        var pattern = chunk.old_lines.items;
        var new_slice = chunk.new_lines.items;
        var found = seek(arena, lines.items, pattern, line_index, chunk.is_end_of_file);
        if (found == null and pattern.len > 0 and pattern[pattern.len - 1].len == 0) {
            pattern = pattern[0 .. pattern.len - 1];
            if (new_slice.len > 0 and new_slice[new_slice.len - 1].len == 0) new_slice = new_slice[0 .. new_slice.len - 1];
            found = seek(arena, lines.items, pattern, line_index, chunk.is_end_of_file);
        }
        const idx = found orelse {
            detail.* = std.fmt.allocPrint(arena, "Failed to find expected lines in {s}", .{path}) catch null;
            return error.OldLinesNotFound;
        };
        try repls.append(arena, .{ .start = idx, .old_len = pattern.len, .new_lines = new_slice, .order = order_ctr });
        order_ctr += 1;
        line_index = idx + pattern.len;
    }

    // 按 (start 升, order 升) 排序,再**逆序**应用 replaceRange。
    // - 不同 start:逆序(高 start 先应用)保证前面的编辑不移位后面未应用的索引。
    // - 相同 start(多个 EOF 纯新增):order 升序 + 逆序遍历 → 在同一位置依次前插,最终恢复
    //   原始 order 顺序(o2 先插、o1 插其前、o0 插最前 → [o0,o1,o2]),不颠倒。
    std.mem.sort(Replacement, repls.items, {}, struct {
        fn lt(_: void, a: Replacement, b: Replacement) bool {
            if (a.start != b.start) return a.start < b.start;
            return a.order < b.order;
        }
    }.lt);
    var result = std.ArrayList([]const u8).empty;
    try result.appendSlice(arena, lines.items);
    var k: usize = repls.items.len;
    while (k > 0) : (k -= 1) {
        const r = repls.items[k - 1];
        result.replaceRange(arena, r.start, r.old_len, r.new_lines) catch return error.OutOfMemory;
    }

    // join '\n' + 结尾换行。
    var buf = std.ArrayList(u8).empty;
    for (result.items, 0..) |ln, i| {
        if (i > 0) try buf.append(arena, '\n');
        try buf.appendSlice(arena, ln);
    }
    try buf.append(arena, '\n'); // 保证结尾换行
    return buf.toOwnedSlice(arena);
}

// ============================================================================
// execute:解析 → 事务性校验 → 落盘 → 结果 JSON
// ============================================================================

const PlannedWrite = struct {
    path: []const u8, // 归一化后的路径(arena owned;相对输入归一化后仍相对,靠 openat(AT.FDCWD) 兜底)
    old_content: []const u8, // 空 = 新建
    new_content: []const u8,
    kind: enum { add, update, delete, move },
    move_from: ?[]const u8 = null, // move:原文件绝对路径(需删除)
};

fn setDetail(ctx: *const ToolContext, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (ctx.error_detail) |slot| {
        slot.* = std.fmt.allocPrint(allocator, fmt, args) catch null;
    }
}

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    // patch 文本:支持 `patch` 或 `input` 字段(codex freeform 用整块;此处 JSON 包一层)。
    const patch_raw = common.extractJsonArg(args, "patch") orelse common.extractJsonArg(args, "input") orelse return error.MissingPatch;
    const patch_text = try util_json.unescapeString(patch_raw, allocator);
    defer allocator.free(patch_text);

    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const hunks = Parser.parse(arena, patch_text) catch |err| {
        setDetail(ctx, allocator, "apply_patch parse error: {s}", .{@errorName(err)});
        return err;
    };
    if (hunks.items.len == 0) return error.EmptyPatch;

    // ── 事务 phase 1:算出所有计划写入 + 校验(全在内存,任一失败即整批放弃)──
    var plans = std.ArrayList(PlannedWrite).empty;
    for (hunks.items) |h| {
        switch (h) {
            .add_file => |af| {
                const abs = try path_mod.normalizeChecked(arena, af.path, .{ .home = ctx.home_dir, .base_dir = ctx.cwd_abs });
                // Add File 撞已存在文件 → 报错(不静默 TRUNC 覆盖,那会把 diff 画成"新建"却毁掉旧文件)。
                if ((read_state.statPath(abs) catch null) != null) {
                    setDetail(ctx, allocator, "apply_patch: cannot add '{s}' (already exists)", .{af.path});
                    return error.AddFileExists;
                }
                try plans.append(arena, .{ .path = abs, .old_content = "", .new_content = af.contents, .kind = .add });
            },
            .delete_file => |df| {
                const abs = try path_mod.normalizeChecked(arena, df.path, .{ .home = ctx.home_dir, .base_dir = ctx.cwd_abs });
                const old = readFileArena(arena, abs) catch {
                    setDetail(ctx, allocator, "apply_patch: cannot delete '{s}' (not found)", .{df.path});
                    return error.FileNotFound;
                };
                try plans.append(arena, .{ .path = abs, .old_content = old, .new_content = "", .kind = .delete });
            },
            .update_file => |uf| {
                const abs = try path_mod.normalizeChecked(arena, uf.path, .{ .home = ctx.home_dir, .base_dir = ctx.cwd_abs });
                const original = readFileArena(arena, abs) catch {
                    setDetail(ctx, allocator, "apply_patch: cannot update '{s}' (not found)", .{uf.path});
                    return error.FileNotFound;
                };
                var detail: ?[]const u8 = null;
                const new_content = deriveNewContents(arena, original, uf.chunks.items, uf.path, &detail) catch |err| {
                    if (detail) |d| setDetail(ctx, allocator, "{s}", .{d});
                    return err;
                };
                if (uf.move_path) |mp| {
                    const dst = try path_mod.normalizeChecked(arena, mp, .{ .home = ctx.home_dir, .base_dir = ctx.cwd_abs });
                    try plans.append(arena, .{ .path = dst, .old_content = original, .new_content = new_content, .kind = .move, .move_from = abs });
                } else {
                    try plans.append(arena, .{ .path = abs, .old_content = original, .new_content = new_content, .kind = .update });
                }
            },
        }
    }

    // ── 权限门:ApplyPatch 的 arg 是不透明 `patch`,path 级 deny 规则 / protected paths 用
    //    tool_name 或 file_path 都匹配不到 → 会绕过整套细粒度权限。补救:phase 2 前把每个计划
    //    路径当 Write 语义逐个喂回权限引擎,任一 deny 或 protected → 整批拒(对齐 Linus 要求)。
    //    bypass 模式(用户明确豁免一切门)跳过。批量的单次 tool 审批不覆盖 explicit deny/protected。
    if (ctx.permission_ctx) |pctx| {
        if (pctx.modeValue() != .bypass) {
            const settings_mod = @import("../permission/settings.zig");
            for (plans.items) |pl| {
                if (settings_mod.isProtectedPath(pl.path)) {
                    setDetail(ctx, allocator, "apply_patch denied: '{s}' is a protected path — edit it individually with Edit/Write so it can be approved.", .{pl.path});
                    return error.PermissionDenied;
                }
                const fp_args = try std.fmt.allocPrint(arena, "{{\"file_path\":\"{s}\"}}", .{pl.path});
                if (@import("../permission.zig").checkPermission(pctx, "Write", fp_args) == .deny) {
                    setDetail(ctx, allocator, "apply_patch denied: writing '{s}' is blocked by a permission deny rule.", .{pl.path});
                    return error.PermissionDenied;
                }
            }
        }
    }

    // ── 事务 phase 2:全部校验通过 → 逐个落盘 ──
    for (plans.items) |pl| {
        switch (pl.kind) {
            .delete => try deleteFile(arena, pl.path),
            .add, .update, .move => {
                try writeFileMkParents(pl.new_content, pl.path);
                // Move = 写新 + 删旧。删旧失败**不吞**——否则源和目标同时存在(内容重复)却报成功。
                if (pl.kind == .move) if (pl.move_from) |from| try deleteFile(arena, from);
                // 刷新 read_state(避免紧接着 Edit 报 stale)。
                if (ctx.read_state) |rs| {
                    if (read_state.statPath(pl.path) catch null) |st| {
                        rs.recordHashed(pl.path, st.mtime_ns, st.size, std.hash.Wyhash.hash(0, pl.new_content)) catch {};
                    }
                }
            },
        }
    }

    // 首个修改文件存 edit_hl_cache(供工具卡 hl-zig 高亮;多文件仅首个)。
    if (ctx.edit_hl_cache) |cache| {
        for (plans.items) |pl| {
            if (pl.kind == .add or pl.kind == .update or pl.kind == .move) {
                cache.put(ctx.progress_tool_id, pl.old_content, pl.new_content);
                break;
            }
        }
    }

    return try buildResult(allocator, arena, plans.items);
}

/// 结果 JSON:含 summary(A/M/D 计数)+ 合并 gitDiff(逐文件拼接,供工具卡渲染)。
fn buildResult(allocator: std.mem.Allocator, arena: std.mem.Allocator, plans: []const PlannedWrite) ![]u8 {
    const patch_mod = @import("../core/patch.zig");
    var git_all = std.ArrayList(u8).empty;
    var n_add: usize = 0;
    var n_mod: usize = 0;
    var n_del: usize = 0;
    for (plans) |pl| {
        switch (pl.kind) {
            .add => n_add += 1,
            .update, .move => n_mod += 1,
            .delete => n_del += 1,
        }
        if (pl.kind != .delete) {
            const patch = patch_mod.compute(arena, pl.old_content, pl.new_content) catch continue;
            const gd = patch_mod.toGitDiff(arena, pl.path, patch.hunks) catch continue;
            try git_all.appendSlice(arena, gd);
        }
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"success\":true,\"added\":{d},\"modified\":{d},\"deleted\":{d},\"gitDiff\":", .{ n_add, n_mod, n_del });
    try std.json.Stringify.encodeJsonString(git_all.items, .{}, &out.writer);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

// ── 文件 IO helpers ──────────────────────────────────────────────────────────
fn readFileArena(arena: std.mem.Allocator, abs: []const u8) ![]u8 {
    const fd = pfs.openZ(abs, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer _ = pfs.close(fd);
    if (read_state.statFd(fd) catch null) |s| {
        if (s.size > MAX_PATCH_FILE_SIZE) return error.FileTooLarge;
    }
    return common.readAllFromFd(fd, arena);
}

fn writeFileMkParents(content: []const u8, abs: []const u8) !void {
    mkdirParents(abs) catch {}; // best-effort;失败交给 openat 暴露
    const fd = pfs.openZ(abs, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch return error.WriteError;
    defer _ = pfs.close(fd);
    // 循环写:write(2) 允许短写(EINTR / ENOSPC 写到一半返回部分字节数,非负)。不循环会静默截断
    // 文件却报成功(对齐 write.zig 的正确写法)。
    var pos: usize = 0;
    while (pos < content.len) {
        const n = pfs.write(fd, content[pos..][0..content.len - pos]);
        if (n < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return error.WriteError;
        }
        if (n == 0) return error.WriteError; // 防死循环
        pos += @intCast(n);
    }
}

/// 为 abs 建所有缺失父目录(mkdir -p 到 dirname)。移植自 write.zig(私有,无法复用)。
fn mkdirParents(path: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash == 0) return;
    const dir = path[0..slash];
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (dir.len >= buf.len) return error.PathTooLong;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            @memcpy(buf[0..i], dir[0..i]);
            buf[i] = 0;
            const seg_z: [*:0]const u8 = @ptrCast(&buf);
            if (std.c.mkdir(seg_z, 0o755) != 0) {
                if (std.c._errno().* != @intFromEnum(std.c.E.EXIST)) return;
            }
        }
    }
}

fn deleteFile(arena: std.mem.Allocator, abs: []const u8) !void {
    const z = try arena.dupeZ(u8, abs);
    if (std.c.unlink(z.ptr) != 0) return error.WriteError;
}

// ============================================================================
// Tests
// ============================================================================
const testing = std.testing;

fn parseOnly(arena: std.mem.Allocator, text: []const u8) !std.ArrayList(Hunk) {
    return Parser.parse(arena, text);
}

test "parse: add file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const patch =
        "*** Begin Patch\n*** Add File: hello.txt\n+Hello\n+World\n*** End Patch\n";
    const hunks = try parseOnly(arena.allocator(), patch);
    try testing.expectEqual(@as(usize, 1), hunks.items.len);
    try testing.expect(hunks.items[0] == .add_file);
    try testing.expectEqualStrings("hello.txt", hunks.items[0].add_file.path);
    try testing.expectEqualStrings("Hello\nWorld\n", hunks.items[0].add_file.contents);
}

test "parse: delete file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hunks = try parseOnly(arena.allocator(), "*** Begin Patch\n*** Delete File: gone.txt\n*** End Patch\n");
    try testing.expect(hunks.items[0] == .delete_file);
    try testing.expectEqualStrings("gone.txt", hunks.items[0].delete_file.path);
}

test "parse: update with move + chunk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const patch =
        "*** Begin Patch\n*** Update File: a.py\n*** Move to: b.py\n@@ def f():\n-old\n+new\n*** End Patch\n";
    const hunks = try parseOnly(arena.allocator(), patch);
    try testing.expect(hunks.items[0] == .update_file);
    const uf = hunks.items[0].update_file;
    try testing.expectEqualStrings("a.py", uf.path);
    try testing.expectEqualStrings("b.py", uf.move_path.?);
    try testing.expectEqual(@as(usize, 1), uf.chunks.items.len);
    try testing.expectEqualStrings("def f():", uf.chunks.items[0].change_context.?);
    try testing.expectEqualStrings("old", uf.chunks.items[0].old_lines.items[0]);
    try testing.expectEqualStrings("new", uf.chunks.items[0].new_lines.items[0]);
}

test "parse: missing begin marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.MissingBeginMarker, parseOnly(arena.allocator(), "*** Add File: x\n+y\n"));
}

test "parse: empty update hunk rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.EmptyUpdateHunk, parseOnly(arena.allocator(), "*** Begin Patch\n*** Update File: a\n*** End Patch\n"));
}

test "deriveNewContents: simple replace" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const patch = "*** Begin Patch\n*** Update File: f.txt\n@@\n foo\n-bar\n+baz\n*** End Patch\n";
    const hunks = try parseOnly(arena, patch);
    var detail: ?[]const u8 = null;
    const out = try deriveNewContents(arena, "foo\nbar\n", hunks.items[0].update_file.chunks.items, "f.txt", &detail);
    try testing.expectEqualStrings("foo\nbaz\n", out);
}

test "deriveNewContents: context not found errors" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const patch = "*** Begin Patch\n*** Update File: f.txt\n@@ nonexistent context\n-a\n+b\n*** End Patch\n";
    const hunks = try parseOnly(arena, patch);
    var detail: ?[]const u8 = null;
    try testing.expectError(error.ContextNotFound, deriveNewContents(arena, "x\ny\n", hunks.items[0].update_file.chunks.items, "f.txt", &detail));
    try testing.expect(detail != null);
}

test "deriveNewContents: pure addition 追加到 EOF(强断言完整输出/顺序,对齐 codex fixture 016)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // fixture 016:line1\nline2 + 纯新增 → line1\nline2\nadded1\nadded2(**追加到末尾**,非顶部)。
    const patch = "*** Begin Patch\n*** Update File: f.txt\n@@\n+added1\n+added2\n*** End Patch\n";
    const hunks = try parseOnly(arena, patch);
    var detail: ?[]const u8 = null;
    const out = try deriveNewContents(arena, "line1\nline2\n", hunks.items[0].update_file.chunks.items, "f.txt", &detail);
    try testing.expectEqualStrings("line1\nline2\nadded1\nadded2\n", out);
}

test "seek: 4-level degradation (rstrip)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const lines = [_][]const u8{ "hello  ", "world" };
    const pat = [_][]const u8{"hello"}; // 精确不中,rstrip 中(文件行有尾空格)
    try testing.expectEqual(@as(?usize, 0), seek(arena, &lines, &pat, 0, false));
}

test "seek: Level-4 Unicode 归一化(ASCII patch 匹配含花引号/破折号的源码)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // 文件行含 U+2018/U+2019 花引号 + U+2014 em-dash;patch 用 ASCII ' 和 -。
    const lines = [_][]const u8{ "x", "print(\u{2018}hi\u{2019})\u{2014}end" };
    const pat = [_][]const u8{"print('hi')-end"}; // ASCII 版
    // 精确/rstrip/trim 全不中,Level-4 归一化(花引号→' em-dash→-)才中。
    try testing.expectEqual(@as(?usize, 1), seek(arena, &lines, &pat, 0, false));
}

test "deriveNewContents: multi-chunk" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const patch = "*** Begin Patch\n*** Update File: f.txt\n@@\n-a\n+A\n@@\n-c\n+C\n*** End Patch\n";
    const hunks = try parseOnly(arena, patch);
    var detail: ?[]const u8 = null;
    const out = try deriveNewContents(arena, "a\nb\nc\n", hunks.items[0].update_file.chunks.items, "f.txt", &detail);
    try testing.expectEqualStrings("A\nb\nC\n", out);
}

// ── codex fixture 移植(scenarios/*):input + patch → expected,逐字对齐 codex 黄金基准 ──
// Update 类场景走 deriveNewContents(纯内存);Add/Delete/Move 走下面的 execute FS 测试。
test "codex fixtures: Update 场景逐字对齐(016/021/022/003)" {
    const Case = struct { name: []const u8, input: []const u8, patch: []const u8, expected: []const u8 };
    const cases = [_]Case{
        // 016 pure_addition:追加到 EOF。
        .{ .name = "016", .input = "line1\nline2\n", .expected = "line1\nline2\nadded line 1\nadded line 2\n", .patch = "*** Begin Patch\n*** Update File: input.txt\n@@\n+added line 1\n+added line 2\n*** End Patch\n" },
        // 021 deletion_only:删中间行。
        .{ .name = "021", .input = "line1\nline2\nline3\n", .expected = "line1\nline3\n", .patch = "*** Begin Patch\n*** Update File: lines.txt\n@@\n line1\n-line2\n line3\n*** End Patch\n" },
        // 022 end_of_file_marker:*** End of File 标记 + 末尾行替换。
        .{ .name = "022", .input = "first\nsecond\n", .expected = "first\nsecond updated\n", .patch = "*** Begin Patch\n*** Update File: tail.txt\n@@\n first\n-second\n+second updated\n*** End of File\n*** End Patch\n" },
        // 003 multiple_chunks:两个 @@ 段分别改。
        .{ .name = "003", .input = "line1\nline2\nline3\nline4\n", .expected = "line1\nchanged2\nline3\nchanged4\n", .patch = "*** Begin Patch\n*** Update File: multi.txt\n@@\n-line2\n+changed2\n@@\n-line4\n+changed4\n*** End Patch\n" },
        // 017 whitespace_padded_hunk_header:`  *** Update File:` 头带前导空白(parser trim 后仍识别)。
        .{ .name = "017", .input = "old\n", .expected = "new\n", .patch = "*** Begin Patch\n  *** Update File: foo.txt\n@@\n-old\n+new\n*** End Patch\n" },
        // 019 unicode_simple:UTF-8 内容逐字节保真(naïve café + emoji)。
        .{ .name = "019", .input = "line1\nnaïve café\nline3\n", .expected = "line1\nnaïve café ✅\nline3\n", .patch = "*** Begin Patch\n*** Update File: foo.txt\n@@\n line1\n-naïve café\n+naïve café ✅\n*** End Patch\n" },
    };
    for (cases) |c| {
        var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        const arena = arena_inst.allocator();
        const hunks = try parseOnly(arena, c.patch);
        var detail: ?[]const u8 = null;
        const out = deriveNewContents(arena, c.input, hunks.items[0].update_file.chunks.items, "f", &detail) catch |e| {
            std.debug.print("fixture {s} failed: {s} detail={?s}\n", .{ c.name, @errorName(e), detail });
            return e;
        };
        testing.expectEqualStrings(c.expected, out) catch |e| {
            std.debug.print("fixture {s} mismatch\n", .{c.name});
            return e;
        };
    }
}

// ── 端到端 execute():真 FS 写盘(temp 目录隔离),证明 parse→apply→write→result 全链 ──
const tt = @import("test_tmp.zig");

fn readWhole(a: std.mem.Allocator, abs: [:0]const u8) ![]u8 {
    const fd = pfs.open(abs.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = pfs.close(fd);
    return common.readAllFromFd(fd, a);
}

test "execute e2e: Update File 真写盘" {
    const a = testing.allocator;
    var pb: [256]u8 = undefined;
    const fpath = tt.path(&pb, "ap_update.txt");
    // 建初始文件。
    {
        const fd = pfs.open(fpath.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        try testing.expect(fd >= 0);
        _ = pfs.write(fd, "foo\nbar\n");
        _ = pfs.close(fd);
    }
    defer _ = std.c.unlink(fpath.ptr);

    var ctx = ToolContext.simple(a);
    ctx.cwd_abs = "/"; // fpath 已是绝对路径
    // patch 文本(JSON 里 patch 字段值,已转义换行)。
    const patch_body = try std.fmt.allocPrint(a, "*** Begin Patch\\n*** Update File: {s}\\n@@\\n foo\\n-bar\\n+baz\\n*** End Patch\\n", .{fpath});
    defer a.free(patch_body);
    const args = try std.fmt.allocPrint(a, "{{\"patch\":\"{s}\"}}", .{patch_body});
    defer a.free(args);

    const res = try execute(&ctx, args);
    defer a.free(res);
    try testing.expect(std.mem.indexOf(u8, res, "\"success\":true") != null);
    try testing.expect(std.mem.indexOf(u8, res, "\"modified\":1") != null);

    const after = try readWhole(a, fpath);
    defer a.free(after);
    try testing.expectEqualStrings("foo\nbaz\n", after);
}

test "execute e2e: Add + Delete 事务性(context 失败则整批不落盘)" {
    const a = testing.allocator;
    var pb1: [256]u8 = undefined;
    var pb2: [256]u8 = undefined;
    const existing = tt.path(&pb1, "ap_tx_existing.txt");
    const to_add = tt.path(&pb2, "ap_tx_added.txt");
    {
        const fd = pfs.open(existing.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        try testing.expect(fd >= 0);
        _ = pfs.write(fd, "keep\n");
        _ = pfs.close(fd);
    }
    defer _ = std.c.unlink(existing.ptr);
    defer _ = std.c.unlink(to_add.ptr);

    var ctx = ToolContext.simple(a);
    ctx.cwd_abs = "/";
    // Add 一个新文件 + Update existing 但 context 对不上(NONEXISTENT)→ 整批应回滚:
    // Add 的文件**不该**存在,existing **不该**被改。
    const patch_body = try std.fmt.allocPrint(a, "*** Begin Patch\\n*** Add File: {s}\\n+new content\\n*** Update File: {s}\\n@@\\n-NONEXISTENT_LINE\\n+x\\n*** End Patch\\n", .{ to_add, existing });
    defer a.free(patch_body);
    const args = try std.fmt.allocPrint(a, "{{\"patch\":\"{s}\"}}", .{patch_body});
    defer a.free(args);

    const res = execute(&ctx, args);
    try testing.expectError(error.OldLinesNotFound, res);

    // 事务性:Add 的文件不存在(phase 1 校验失败,phase 2 从未执行)。
    try testing.expectError(error.FileNotFound, readWhole(a, to_add));
    // existing 未被改动。
    const kept = try readWhole(a, existing);
    defer a.free(kept);
    try testing.expectEqualStrings("keep\n", kept);
}

test "execute e2e: Move(重命名到新目录)写新 + 删旧(codex fixture 004)" {
    const a = testing.allocator;
    var pb1: [256]u8 = undefined;
    var pb2: [256]u8 = undefined;
    const src = tt.path(&pb1, "ap_move_src.txt");
    const dst = tt.path(&pb2, "ap_move_dst.txt");
    {
        const fd = pfs.open(src.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        try testing.expect(fd >= 0);
        _ = pfs.write(fd, "old content\n");
        _ = pfs.close(fd);
    }
    defer _ = std.c.unlink(src.ptr);
    defer _ = std.c.unlink(dst.ptr);

    var ctx = ToolContext.simple(a);
    ctx.cwd_abs = "/";
    const patch_body = try std.fmt.allocPrint(a, "*** Begin Patch\\n*** Update File: {s}\\n*** Move to: {s}\\n@@\\n-old content\\n+new content\\n*** End Patch\\n", .{ src, dst });
    defer a.free(patch_body);
    const args = try std.fmt.allocPrint(a, "{{\"patch\":\"{s}\"}}", .{patch_body});
    defer a.free(args);

    const res = try execute(&ctx, args);
    defer a.free(res);
    // gitDiff 字段非空(展示层证据,消除"声明没测")。
    try testing.expect(std.mem.indexOf(u8, res, "\"gitDiff\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, res, "new content") != null);

    // 新文件存在且内容对;旧文件已删。
    const moved = try readWhole(a, dst);
    defer a.free(moved);
    try testing.expectEqualStrings("new content\n", moved);
    try testing.expectError(error.FileNotFound, readWhole(a, src));
}

test "execute e2e: Add File 撞已存在文件 → 报错不覆盖(比 codex 更安全)" {
    const a = testing.allocator;
    var pb: [256]u8 = undefined;
    const fpath = tt.path(&pb, "ap_add_exists.txt");
    {
        const fd = pfs.open(fpath.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        try testing.expect(fd >= 0);
        _ = pfs.write(fd, "PRECIOUS\n");
        _ = pfs.close(fd);
    }
    defer _ = std.c.unlink(fpath.ptr);

    var ctx = ToolContext.simple(a);
    ctx.cwd_abs = "/";
    const patch_body = try std.fmt.allocPrint(a, "*** Begin Patch\\n*** Add File: {s}\\n+overwrite\\n*** End Patch\\n", .{fpath});
    defer a.free(patch_body);
    const args = try std.fmt.allocPrint(a, "{{\"patch\":\"{s}\"}}", .{patch_body});
    defer a.free(args);

    try testing.expectError(error.AddFileExists, execute(&ctx, args));
    // 原文件未被 TRUNC。
    const kept = try readWhole(a, fpath);
    defer a.free(kept);
    try testing.expectEqualStrings("PRECIOUS\n", kept);
}

test "execute: protected path(.env)拦住 ApplyPatch(不再绕过细粒度权限)" {
    const a = testing.allocator;
    var pb: [256]u8 = undefined;
    // 名为 .env 的 protected 文件(isProtectedPath 命中)。旧版 ApplyPatch 会绕过 protected 直接改。
    const fpath = tt.path(&pb, ".env");
    {
        const fd = pfs.open(fpath.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        try testing.expect(fd >= 0);
        _ = pfs.write(fd, "SECRET=1\n");
        _ = pfs.close(fd);
    }
    defer _ = std.c.unlink(fpath.ptr);

    const permission = @import("../permission.zig");
    var pctx = permission.createContext(.default, a); // 非 bypass → 权限门生效
    var ctx = ToolContext.simple(a);
    ctx.cwd_abs = "/";
    ctx.permission_ctx = &pctx;
    const patch_body = try std.fmt.allocPrint(a, "*** Begin Patch\\n*** Update File: {s}\\n@@\\n-SECRET=1\\n+SECRET=2\\n*** End Patch\\n", .{fpath});
    defer a.free(patch_body);
    const args = try std.fmt.allocPrint(a, "{{\"patch\":\"{s}\"}}", .{patch_body});
    defer a.free(args);

    try testing.expectError(error.PermissionDenied, execute(&ctx, args));
    // 文件未被改(protected 在 phase 2 前拦下)。
    const kept = try readWhole(a, fpath);
    defer a.free(kept);
    try testing.expectEqualStrings("SECRET=1\n", kept);
}

test "接线: ApplyPatch 在 registry 且 dispatch 路由到它" {
    const tools = @import("../tools.zig");
    try testing.expect(tools.getTool("ApplyPatch") != null);
}

test "接线: ApplyPatch / NotebookEdit 权限类别是 write(不绕过写权限门)" {
    const category = @import("../permission/category.zig");
    try testing.expect(category.getToolCategory("ApplyPatch") == .write);
    // NotebookEdit 此前落默认 .read(写工具被当只读,plan 模式静默放行)——本轮修进 .write,加断言锁定。
    try testing.expect(category.getToolCategory("NotebookEdit") == .write);
}
