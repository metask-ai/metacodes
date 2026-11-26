//! 行级结构化 diff（unified-diff 风格 hunk）。
//!
//! 用于 Write/Edit 返回 structuredPatch + gitDiff，让上层（IDE/UI/模型）看到具体改了什么，
//! 而不是只有 {"success":true}。
//!
//! 算法：经典 LCS（最长公共子序列）按行对比 → 合并连续变更为 hunk（带 3 行上下文）。
//! 复杂度 O(n*m)；对常见编辑（几百行）足够。超大文件由调用方的 size 上限挡住。
//!
//! 输出：
//! - structuredPatch JSON：[{"oldStart":N,"oldLines":N,"newStart":N,"newLines":N,
//!     "lines":["-old","+new"," ctx"]}]
//! - gitDiff 文本：标准 `--- a/x` / `+++ b/x` / `@@ -a,b +c,d @@` 格式

const std = @import("std");
const util_json = @import("metacodes-base").util.json;

const CONTEXT_LINES: usize = 3;

/// 一条 diff 行：类型 + 内容（不含换行）。
const DiffOp = enum { keep, del, add };
const DiffLine = struct { op: DiffOp, text: []const u8 };

/// 把文本切成行（不含 '\n'）。尾部若以 '\n' 结尾不产生空末行。
fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines = std.ArrayList([]const u8).empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0 and it.peek() == null) break; // 尾随 \n
        try lines.append(allocator, ln);
    }
    return try lines.toOwnedSlice(allocator);
}

/// LCS 表 → diff op 序列。
fn diffLines(allocator: std.mem.Allocator, a: [][]const u8, b: [][]const u8) ![]DiffLine {
    const n = a.len;
    const m = b.len;
    // dp[(n+1)*(m+1)]
    const dp = try allocator.alloc(usize, (n + 1) * (m + 1));
    defer allocator.free(dp);
    @memset(dp, 0);
    const idx = struct {
        fn at(i: usize, j: usize, cols: usize) usize {
            return i * cols + j;
        }
    };
    const cols = m + 1;
    // 自底向上填 LCS 表
    var i: usize = n;
    while (i > 0) : (i -= 1) {
        var j: usize = m;
        while (j > 0) : (j -= 1) {
            if (std.mem.eql(u8, a[i - 1], b[j - 1])) {
                dp[idx.at(i - 1, j - 1, cols)] = dp[idx.at(i, j, cols)] + 1;
            } else {
                dp[idx.at(i - 1, j - 1, cols)] = @max(dp[idx.at(i, j - 1, cols)], dp[idx.at(i - 1, j, cols)]);
            }
        }
    }

    var ops = std.ArrayList(DiffLine).empty;
    errdefer ops.deinit(allocator);
    i = 0;
    var j: usize = 0;
    while (i < n and j < m) {
        if (std.mem.eql(u8, a[i], b[j])) {
            try ops.append(allocator, .{ .op = .keep, .text = a[i] });
            i += 1;
            j += 1;
        } else if (dp[idx.at(i + 1, j, cols)] >= dp[idx.at(i, j + 1, cols)]) {
            try ops.append(allocator, .{ .op = .del, .text = a[i] });
            i += 1;
        } else {
            try ops.append(allocator, .{ .op = .add, .text = b[j] });
            j += 1;
        }
    }
    while (i < n) : (i += 1) try ops.append(allocator, .{ .op = .del, .text = a[i] });
    while (j < m) : (j += 1) try ops.append(allocator, .{ .op = .add, .text = b[j] });
    return try ops.toOwnedSlice(allocator);
}

pub const Hunk = struct {
    old_start: usize,
    old_lines: usize,
    new_start: usize,
    new_lines: usize,
    /// 借用 ops 里的 text 切片；带前缀字符（' '/'-'/'+'）在序列化时加。
    ops: []DiffLine,
};

/// 把变更合并成 unified-diff hunk:前后各带至多 CONTEXT_LINES 行上下文,两处变更之间
/// 未变行数 ≤ 2×CONTEXT_LINES 时并进同一个 hunk(否则两个 hunk 的上下文会重叠)。
///
/// 每个 hunk 的头部行数严格等于正文里对应侧的行数——`git apply` 按头部计数读正文,
/// 二者不一致就是一份坏补丁。某一侧行数为 0 时,起始行号按 unified-diff 约定写"其前
/// 一行"(新建文件是 `-0,0`)。
fn buildHunks(allocator: std.mem.Allocator, ops: []DiffLine) ![]Hunk {
    var hunks = std.ArrayList(Hunk).empty;
    errdefer hunks.deinit(allocator);

    // ops[i] 处的 1-based 行号;每轮循环结束时与 i 同步。
    var old_ln: usize = 1;
    var new_ln: usize = 1;
    var i: usize = 0;
    var prev_end: usize = 0; // 上一个 hunk 的 ops 终点:前置上下文不得回退越过它
    while (i < ops.len) {
        if (ops[i].op == .keep) {
            old_ln += 1;
            new_ln += 1;
            i += 1;
            continue;
        }
        const lead = @min(CONTEXT_LINES, i - prev_end);
        const start = i - lead;

        // 吞并后续变更,直到一段未变行长到足以把下一处变更分成独立 hunk。
        var last_change = i;
        var j = i;
        while (j < ops.len) : (j += 1) {
            if (ops[j].op != .keep) {
                last_change = j;
            } else if (j - last_change > 2 * CONTEXT_LINES) break;
        }
        const end = @min(last_change + 1 + CONTEXT_LINES, ops.len);

        var old_count: usize = 0;
        var new_count: usize = 0;
        for (ops[start..end]) |op| switch (op.op) {
            .keep => {
                old_count += 1;
                new_count += 1;
            },
            .del => old_count += 1,
            .add => new_count += 1,
        };
        const old_start = old_ln - lead;
        const new_start = new_ln - lead;
        try hunks.append(allocator, .{
            .old_start = if (old_count == 0) old_start - 1 else old_start,
            .old_lines = old_count,
            .new_start = if (new_count == 0) new_start - 1 else new_start,
            .new_lines = new_count,
            .ops = ops[start..end],
        });

        for (ops[i..end]) |op| switch (op.op) {
            .keep => {
                old_ln += 1;
                new_ln += 1;
            },
            .del => old_ln += 1,
            .add => new_ln += 1,
        };
        i = end;
        prev_end = end;
    }
    return try hunks.toOwnedSlice(allocator);
}

/// 计算结果：拥有 ops 底层数组 + hunks 数组。hunks[].ops 借用 ops 的子切片。
/// hunks[].ops[].text 借用调用方传入的 old_text/new_text 字节——调用方须保证其存活到
/// 本结构 deinit + 所有序列化完成。
pub const Patch = struct {
    ops: []DiffLine,
    hunks: []Hunk,

    pub fn deinit(self: *Patch, allocator: std.mem.Allocator) void {
        allocator.free(self.ops);
        allocator.free(self.hunks);
    }
};

/// 计算 old→new 的 diff。调用方负责 `patch.deinit(allocator)`。
pub fn compute(allocator: std.mem.Allocator, old_text: []const u8, new_text: []const u8) !Patch {
    const a = try splitLines(allocator, old_text);
    defer allocator.free(a);
    const b = try splitLines(allocator, new_text);
    defer allocator.free(b);
    const ops = try diffLines(allocator, a, b);
    errdefer allocator.free(ops);
    const hunks = try buildHunks(allocator, ops);
    return .{ .ops = ops, .hunks = hunks };
}

/// `compute` for inputs whose size the caller does not control. The LCS table
/// is O(n·m) cells, so a one-line change in a 3 000-line file costs 9 M cells
/// (72 MiB) there. Here the common leading and trailing lines are matched
/// directly and only the differing middle builds a table; null means that
/// middle alone would still exceed `max_cells`. The result has the same shape
/// and line numbering as `compute`'s; where several minimal diffs exist it may
/// pick a different one.
pub fn computeBounded(allocator: std.mem.Allocator, old_text: []const u8, new_text: []const u8, max_cells: usize) !?Patch {
    const a = try splitLines(allocator, old_text);
    defer allocator.free(a);
    const b = try splitLines(allocator, new_text);
    defer allocator.free(b);

    var prefix: usize = 0;
    while (prefix < a.len and prefix < b.len and std.mem.eql(u8, a[prefix], b[prefix])) prefix += 1;
    var suffix: usize = 0;
    while (suffix < a.len - prefix and suffix < b.len - prefix and
        std.mem.eql(u8, a[a.len - 1 - suffix], b[b.len - 1 - suffix])) suffix += 1;
    const mid_a = a[prefix .. a.len - suffix];
    const mid_b = b[prefix .. b.len - suffix];
    if ((mid_a.len +| 1) *| (mid_b.len +| 1) > max_cells) return null;

    const middle = try diffLines(allocator, mid_a, mid_b);
    defer allocator.free(middle);
    const ops = try allocator.alloc(DiffLine, prefix + middle.len + suffix);
    errdefer allocator.free(ops);
    for (a[0..prefix], ops[0..prefix]) |line, *op| op.* = .{ .op = .keep, .text = line };
    @memcpy(ops[prefix..][0..middle.len], middle);
    for (a[a.len - suffix ..], ops[prefix + middle.len ..]) |line, *op| op.* = .{ .op = .keep, .text = line };
    const hunks = try buildHunks(allocator, ops);
    return .{ .ops = ops, .hunks = hunks };
}

/// 序列化为 structuredPatch JSON 数组。
pub fn toStructuredJson(allocator: std.mem.Allocator, hunks: []const Hunk) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (hunks, 0..) |h, hi| {
        if (hi > 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"oldStart\":{d},\"oldLines\":{d},\"newStart\":{d},\"newLines\":{d},\"lines\":[",
            .{ h.old_start, h.old_lines, h.new_start, h.new_lines },
        );
        for (h.ops, 0..) |op, oi| {
            if (oi > 0) try out.writer.writeByte(',');
            const prefix: u8 = switch (op.op) {
                .keep => ' ',
                .del => '-',
                .add => '+',
            };
            var line_buf: std.Io.Writer.Allocating = .init(allocator);
            defer line_buf.deinit();
            try line_buf.writer.writeByte(prefix);
            try line_buf.writer.writeAll(op.text);
            try util_json.writeJsonString(&out.writer, line_buf.written());
        }
        try out.writer.writeAll("]}");
    }
    try out.writer.writeByte(']');
    return try out.toOwnedSlice();
}

/// 序列化为 git unified diff 文本。
pub fn toGitDiff(allocator: std.mem.Allocator, path: []const u8, hunks: []const Hunk) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (hunks.len == 0) return try out.toOwnedSlice();
    try out.writer.print("--- a/{s}\n+++ b/{s}\n", .{ path, path });
    for (hunks) |h| {
        try out.writer.print("@@ -{d},{d} +{d},{d} @@\n", .{ h.old_start, h.old_lines, h.new_start, h.new_lines });
        for (h.ops) |op| {
            const prefix: u8 = switch (op.op) {
                .keep => ' ',
                .del => '-',
                .add => '+',
            };
            try out.writer.writeByte(prefix);
            try out.writer.writeAll(op.text);
            try out.writer.writeByte('\n');
        }
    }
    return try out.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "splitLines basic" {
    const a = std.testing.allocator;
    const lines = try splitLines(a, "x\ny\nz\n");
    defer a.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("y", lines[1]);
}

test "compute + structured json single change" {
    const a = std.testing.allocator;
    var patch = try compute(a, "a\nb\nc\n", "a\nB\nc\n");
    defer patch.deinit(a);
    try std.testing.expect(patch.hunks.len >= 1);
    const j = try toStructuredJson(a, patch.hunks);
    defer a.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"-b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"+B\"") != null);
}

test "git diff format" {
    const a = std.testing.allocator;
    var patch = try compute(a, "one\ntwo\n", "one\ntwo\nthree\n");
    defer patch.deinit(a);
    const d = try toGitDiff(a, "f.txt", patch.hunks);
    defer a.free(d);
    try std.testing.expect(std.mem.indexOf(u8, d, "--- a/f.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "+++ b/f.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "@@") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "+three") != null);
}

test "no change yields no hunks" {
    const a = std.testing.allocator;
    var patch = try compute(a, "same\n", "same\n");
    defer patch.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), patch.hunks.len);
}

test "computeBounded diffs a one-line change in a large file inside a small table" {
    const a = std.testing.allocator;
    var old_text: std.Io.Writer.Allocating = .init(a);
    defer old_text.deinit();
    var new_text: std.Io.Writer.Allocating = .init(a);
    defer new_text.deinit();
    for (0..3000) |i| {
        try old_text.writer.print("line {d}\n", .{i});
        try new_text.writer.print("line {d}{s}\n", .{ i, if (i == 1500) " changed" else "" });
    }
    // The whole-file table would be 3001² ≈ 9 M cells; the differing middle is 2×2.
    var patch = (try computeBounded(a, old_text.written(), new_text.written(), 16)) orelse
        return error.TestUnexpectedResult;
    defer patch.deinit(a);
    const d = try toGitDiff(a, "big.txt", patch.hunks);
    defer a.free(d);
    try std.testing.expectEqualStrings(
        "--- a/big.txt\n+++ b/big.txt\n@@ -1498,7 +1498,7 @@\n" ++
            " line 1497\n line 1498\n line 1499\n-line 1500\n+line 1500 changed\n line 1501\n line 1502\n line 1503\n",
        d,
    );
}

test "computeBounded agrees with compute on small inputs and refuses an oversized middle" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "a\nb\nc\n", "a\nB\nc\n" },
        .{ "one\ntwo\n", "one\ntwo\nthree\n" },
        .{ "", "x\ny\n" },
        .{ "x\ny\n", "" },
        .{ "same\n", "same\n" },
    };
    for (cases) |case| {
        var full = try compute(a, case[0], case[1]);
        defer full.deinit(a);
        var bounded = (try computeBounded(a, case[0], case[1], 1 << 20)) orelse return error.TestUnexpectedResult;
        defer bounded.deinit(a);
        const want = try toGitDiff(a, "f", full.hunks);
        defer a.free(want);
        const got = try toGitDiff(a, "f", bounded.hunks);
        defer a.free(got);
        try std.testing.expectEqualStrings(want, got);
    }
    // Every line differs: trimming cannot help, so the bound decides.
    try std.testing.expect((try computeBounded(a, "a\nb\nc\n", "x\ny\nz\n", 15)) == null);
    var fits = (try computeBounded(a, "a\nb\nc\n", "x\ny\nz\n", 16)) orelse return error.TestUnexpectedResult;
    fits.deinit(a);
}

/// Every hunk header's counts must equal its body, and hunks must not overlap:
/// that is what `git apply` checks before it touches a file.
fn expectWellFormed(diff: []const u8) !void {
    var lines = std.mem.splitScalar(u8, diff, '\n');
    var want_old: usize = 0;
    var want_new: usize = 0;
    var seen_old: usize = 0;
    var seen_new: usize = 0;
    var next_free_old: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@ ")) {
            try std.testing.expectEqual(want_old, seen_old);
            try std.testing.expectEqual(want_new, seen_new);
            var it = std.mem.tokenizeAny(u8, line, "@ -+,");
            const old_start = try std.fmt.parseInt(usize, it.next().?, 10);
            want_old = try std.fmt.parseInt(usize, it.next().?, 10);
            _ = it.next();
            want_new = try std.fmt.parseInt(usize, it.next().?, 10);
            seen_old = 0;
            seen_new = 0;
            try std.testing.expect(old_start + 1 > next_free_old or want_old == 0);
            next_free_old = old_start + want_old;
            continue;
        }
        if (std.mem.startsWith(u8, line, "--- ") or std.mem.startsWith(u8, line, "+++ ") or line.len == 0) continue;
        switch (line[0]) {
            ' ' => {
                seen_old += 1;
                seen_new += 1;
            },
            '-' => seen_old += 1,
            '+' => seen_new += 1,
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(want_old, seen_old);
    try std.testing.expectEqual(want_new, seen_new);
}

fn numbered(a: std.mem.Allocator, n: usize, changed: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    for (1..n + 1) |i| {
        const mark = std.mem.indexOfScalar(usize, changed, i) != null;
        try out.writer.print("l{d}{s}\n", .{ i, if (mark) "*" else "" });
    }
    return out.toOwnedSlice();
}

test "hunk headers count exactly the lines they carry" {
    const a = std.testing.allocator;
    const old = try numbered(a, 30, &.{});
    defer a.free(old);
    // Gaps of 3, 4, 6 and 7 unchanged lines between changes: ≤ 6 merges, 7 splits.
    const layouts = [_][]const usize{ &.{10}, &.{ 10, 14 }, &.{ 10, 15 }, &.{ 10, 17 }, &.{ 10, 18 }, &.{ 1, 30 }, &.{2} };
    for (layouts) |changed| {
        const new = try numbered(a, 30, changed);
        defer a.free(new);
        var patch = try compute(a, old, new);
        defer patch.deinit(a);
        const d = try toGitDiff(a, "f", patch.hunks);
        defer a.free(d);
        try expectWellFormed(d);
    }

    // One change with more than CONTEXT_LINES unchanged lines after it.
    const one = try numbered(a, 30, &.{10});
    defer a.free(one);
    var single = try compute(a, old, one);
    defer single.deinit(a);
    const d = try toGitDiff(a, "f", single.hunks);
    defer a.free(d);
    try std.testing.expectEqualStrings("--- a/f\n+++ b/f\n@@ -7,7 +7,7 @@\n l7\n l8\n l9\n-l10\n+l10*\n l11\n l12\n l13\n", d);

    // A gap of 6 is one hunk, a gap of 7 is two.
    const six = try numbered(a, 30, &.{ 10, 17 });
    defer a.free(six);
    var merged = try compute(a, old, six);
    defer merged.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), merged.hunks.len);
    const seven = try numbered(a, 30, &.{ 10, 18 });
    defer a.free(seven);
    var split = try compute(a, old, seven);
    defer split.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), split.hunks.len);
}

test "a side with no lines starts at the line before it" {
    const a = std.testing.allocator;
    var created = try compute(a, "", "x\ny\n");
    defer created.deinit(a);
    const c = try toGitDiff(a, "f", created.hunks);
    defer a.free(c);
    try std.testing.expectEqualStrings("--- a/f\n+++ b/f\n@@ -0,0 +1,2 @@\n+x\n+y\n", c);
    var deleted = try compute(a, "x\ny\n", "");
    defer deleted.deinit(a);
    const d = try toGitDiff(a, "f", deleted.hunks);
    defer a.free(d);
    try std.testing.expectEqualStrings("--- a/f\n+++ b/f\n@@ -1,2 +0,0 @@\n-x\n-y\n", d);
}
