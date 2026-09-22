//! 命令历史：内存 ring（cap=1000） + `~/.metacodes/history` 文件持久化。
//!
//! 典型工作流：
//! 1. REPL 启动：`History.init` → 从文件读已有行到内存
//! 2. 每次用户提交一行：`append(line)` 到内存
//! 3. ↑ 键：`prev()` 返回上一条（临时暂存 pending 输入）
//! 4. ↓ 键：`next()` 回到更新的一条或 pending
//! 5. REPL 退出：`save()` 写回文件 + fsync
//!
//! 不在 append 时立即写盘——一次 session 的批量追加更省 IO；崩溃时最多丢当前 session。

const std = @import("std");
const tt = @import("../tools/test_tmp.zig"); // 测试 fixture 唯一路径(并发隔离)
const pfs = @import("platform").fs;
const util_json = @import("../util/json.zig");

pub const MAX_ENTRIES: usize = 1000;

pub const History = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]u8), // 每条 owned
    /// 浏览历史时的"临时原地暂存"——用户未提交的当前编辑缓冲
    pending: ?[]u8 = null,
    /// 浏览位置：null = 未浏览（cursor 在 pending），>=0 = entries 索引
    cursor: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |e| self.allocator.free(e);
        self.entries.deinit(self.allocator);
        if (self.pending) |p| self.allocator.free(p);
    }

    /// 追加一条已提交的命令行（owned 复制）。
    /// 忽略空行和与前一条重复的行（避免连续 ↑↑↑ 重复）。
    pub fn append(self: *History, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, trimmed)) return;
        }

        const owned = try self.allocator.dupe(u8, trimmed);
        errdefer self.allocator.free(owned);
        try self.entries.append(self.allocator, owned);

        // 环形：超出上限时丢最老的
        while (self.entries.items.len > MAX_ENTRIES) {
            self.allocator.free(self.entries.items[0]);
            _ = self.entries.orderedRemove(0);
        }

        // 新 append 意味着结束了上次的浏览
        self.cursor = null;
        if (self.pending) |p| {
            self.allocator.free(p);
            self.pending = null;
        }
    }

    /// 开始（或继续）向上浏览。第一次调用会把 `current_buf` 作为 pending 暂存。
    /// 返回浏览到的那条（借用，不得释放），没有更早的返回 null。
    pub fn prev(self: *History, current_buf: []const u8) !?[]const u8 {
        if (self.entries.items.len == 0) return null;
        if (self.cursor == null) {
            self.pending = try self.allocator.dupe(u8, current_buf);
            self.cursor = self.entries.items.len - 1;
            return self.entries.items[self.cursor.?];
        }
        const c = self.cursor.?;
        if (c == 0) return null; // 已到最老
        self.cursor = c - 1;
        return self.entries.items[self.cursor.?];
    }

    /// 向下浏览。到最新一条之后返回 pending 并退出浏览模式；pending 为空则返 ""。
    pub fn next(self: *History) ?[]const u8 {
        const c = self.cursor orelse return null;
        if (c + 1 < self.entries.items.len) {
            self.cursor = c + 1;
            return self.entries.items[self.cursor.?];
        }
        // 退出浏览：返回 pending
        self.cursor = null;
        const p = self.pending orelse "";
        return p;
    }

    /// 从文件加载（如果存在）。
    /// 格式：JSONL——每行一个 JSON 字符串（`"cmd with \n newline"`）。
    /// 向后兼容：不以 `"` 开头的行按旧版纯文本整行处理（自动迁移，下次 save 会写成 JSONL）。
    pub fn loadFromFile(self: *History, path: []const u8) !void {
        const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch return;
        defer _ = pfs.close(fd);

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = pfs.readZ(fd, &chunk) catch return error.ReadError;
            if (n == 0) break;
            try buf.appendSlice(self.allocator, chunk[0..@as(usize, @intCast(n))]);
        }

        var it = std.mem.splitScalar(u8, buf.items, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '"') {
                // JSONL 行：解析为字符串
                const parsed = std.json.parseFromSlice([]const u8, self.allocator, trimmed, .{}) catch {
                    // 解析失败 → 当旧版纯文本兜底
                    try self.append(trimmed);
                    continue;
                };
                defer parsed.deinit();
                try self.append(parsed.value);
            } else {
                // 旧版纯文本行
                try self.append(trimmed);
            }
        }
    }

    /// 保存到文件（覆盖写，JSONL 格式）。路径必须绝对；父目录不存在会创建。
    /// 每条命令写成一行 JSON 字符串——含换行的多行命令也能安全 round-trip。
    /// 保存后 fsync 确保落盘。
    pub fn saveToFile(self: *const History, path: []const u8) !void {
        // 确保父目录存在（mkdir -p 父目录）
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            const parent = path[0..slash];
            if (parent.len > 0) {
                const parent_z = try allocatorDupeZ(self.allocator, parent);
                defer self.allocator.free(parent_z);
                _ = pfs.mkdir(parent_z, 0o700);
            }
        }

        const path_z = try allocatorDupeZ(self.allocator, path);
        defer self.allocator.free(path_z);

        const fd = pfs.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.WriteError;
        defer _ = pfs.close(fd);

        for (self.entries.items) |entry| {
            var line: std.Io.Writer.Allocating = .init(self.allocator);
            defer line.deinit();
            util_json.writeJsonString(&line.writer, entry) catch continue;
            line.writer.writeByte('\n') catch continue;
            const bytes = line.written();
            _ = pfs.write(fd, bytes);
        }
        _ = pfs.fsync(fd);
    }

    pub fn len(self: *const History) usize {
        return self.entries.items.len;
    }
};

fn allocatorDupeZ(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    return a.dupeZ(u8, s);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "History: empty init" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try testing.expect(h.len() == 0);
    try testing.expect((try h.prev("")) == null);
}

test "History: append and prev" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.append("a");
    try h.append("b");
    try testing.expectEqualStrings("b", (try h.prev("")).?);
    try testing.expectEqualStrings("a", (try h.prev("")).?);
    try testing.expect((try h.prev("")) == null);
}

test "History: dedup consecutive" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.append("same");
    try h.append("same");
    try h.append("same");
    try testing.expect(h.len() == 1);
}

test "History: skip empty lines" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.append("");
    try h.append("   ");
    try h.append("\t\n");
    try testing.expect(h.len() == 0);
}

test "History: trim whitespace on append" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.append("  hello  \n");
    try testing.expectEqualStrings("hello", h.entries.items[0]);
}

test "History: prev preserves pending buffer" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.append("old");
    // 用户打了一半 "partial"，按上箭头
    try testing.expectEqualStrings("old", (try h.prev("partial")).?);
    // 按下键回到 pending
    try testing.expectEqualStrings("partial", h.next().?);
}

test "History: next past newest returns empty pending" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.append("only");
    _ = try h.prev(""); // cursor 指向 "only"
    try testing.expectEqualStrings("", h.next().?); // 回到空 pending
}

test "History: roundtrip save/load" {
    var path_buf: [512]u8 = undefined;
    const path = tt.path(&path_buf, "history-test.txt");
    defer _ = std.c.unlink(path.ptr);

    var h1 = History.init(testing.allocator);
    try h1.append("alpha");
    try h1.append("beta");
    try h1.append("gamma");
    try h1.saveToFile(path);
    h1.deinit();

    var h2 = History.init(testing.allocator);
    defer h2.deinit();
    try h2.loadFromFile(path);
    try testing.expect(h2.len() == 3);
    try testing.expectEqualStrings("gamma", (try h2.prev("")).?);
    try testing.expectEqualStrings("beta", (try h2.prev("")).?);
    try testing.expectEqualStrings("alpha", (try h2.prev("")).?);
}

test "History: multiline command survives JSONL round-trip" {
    var path_buf: [512]u8 = undefined;
    const path = tt.path(&path_buf, "history-multiline.jsonl");
    defer _ = std.c.unlink(path.ptr);

    var h1 = History.init(testing.allocator);
    try h1.append("line1\nline2\nline3");
    try h1.append("single");
    try h1.saveToFile(path);
    h1.deinit();

    var h2 = History.init(testing.allocator);
    defer h2.deinit();
    try h2.loadFromFile(path);
    // 多行命令应作为单条 entry 还原（不被换行拆成 3 条）
    try testing.expectEqual(@as(usize, 2), h2.len());
    try testing.expectEqualStrings("single", (try h2.prev("")).?);
    try testing.expectEqualStrings("line1\nline2\nline3", (try h2.prev("")).?);
}

test "History: legacy plain-text file auto-migrates" {
    var path_buf: [512]u8 = undefined;
    const path = tt.path(&path_buf, "history-legacy.txt");
    defer _ = std.c.unlink(path.ptr);
    // 手写旧版纯文本（无引号）
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    const legacy = "oldcmd1\noldcmd2\n";
    _ = pfs.write(fd, legacy);
    _ = pfs.close(fd);

    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.loadFromFile(path);
    try testing.expectEqual(@as(usize, 2), h.len());
    try testing.expectEqualStrings("oldcmd2", (try h.prev("")).?);
}

test "History: load missing file is ok" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.loadFromFile("/tmp/cc-zig-nonexistent-history-xxxxxxx.txt");
    try testing.expect(h.len() == 0);
}

test "History: append after browse clears pending" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.append("a");
    _ = try h.prev("mid-edit");
    try h.append("b");
    // 浏览状态被重置
    try testing.expect(h.cursor == null);
    try testing.expect(h.pending == null);
}
