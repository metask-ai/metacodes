//! 多行输入累加器。
//!
//! 在 LineEditor（单行编辑器）之上运作：
//! - 每次 LineEditor 收到 .commit 时，调用 `feedLine(line)`
//! - Accumulator 决定：这条是否真正结束本次输入，或只是多行块的中间一行
//!
//! 规则（对齐 Python REPL / Anthropic 风格）：
//! - 单行内以 `\` 结尾（行尾无空格），去掉 `\` 后续行
//! - 独占一行 `"""` 切换多行块模式：开启后每行都加入，直到遇到再一个 `"""`
//! - 多行块中嵌套 `\` 续行不起作用——纯文本模式
//!
//! feedLine 返回：
//! - `.done`：输入完成，`buffer` 中是完整结果
//! - `.more`：需要继续，下一行请继续喂

const std = @import("std");

pub const Status = enum { done, more };

pub const Accumulator = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    in_block: bool = false,

    pub fn init(allocator: std.mem.Allocator) Accumulator {
        return .{ .allocator = allocator, .buffer = .empty };
    }

    pub fn deinit(self: *Accumulator) void {
        self.buffer.deinit(self.allocator);
    }

    /// 投入一行（不含末尾 '\n'）。返回状态。
    /// `.done` 时调用者应从 `finish()` 取走完整字节。
    pub fn feedLine(self: *Accumulator, line: []const u8) !Status {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");

        // 独占 """ → 切换块模式
        if (std.mem.eql(u8, trimmed, "\"\"\"")) {
            if (self.in_block) {
                self.in_block = false;
                return .done;
            } else {
                self.in_block = true;
                return .more;
            }
        }

        if (self.in_block) {
            // 块内：原样追加 line + \n
            try self.buffer.appendSlice(self.allocator, line);
            try self.buffer.append(self.allocator, '\n');
            return .more;
        }

        // 普通模式：检测尾部 '\' 续行
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\\') {
            // 去掉最后的 '\'，加 '\n'，等下一行
            try self.buffer.appendSlice(self.allocator, trimmed[0 .. trimmed.len - 1]);
            try self.buffer.append(self.allocator, '\n');
            return .more;
        }

        // 普通单行：把这行追加，done
        try self.buffer.appendSlice(self.allocator, line);
        return .done;
    }

    /// 取走并清空 buffer。
    pub fn finish(self: *Accumulator) ![]u8 {
        const out = try self.allocator.dupe(u8, self.buffer.items);
        self.buffer.clearRetainingCapacity();
        self.in_block = false;
        return out;
    }

    pub fn reset(self: *Accumulator) void {
        self.buffer.clearRetainingCapacity();
        self.in_block = false;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Accumulator: single line is done" {
    var a = Accumulator.init(testing.allocator);
    defer a.deinit();
    try testing.expect((try a.feedLine("hello")) == .done);
    const out = try a.finish();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "Accumulator: backslash continuation" {
    var a = Accumulator.init(testing.allocator);
    defer a.deinit();
    try testing.expect((try a.feedLine("line1\\")) == .more);
    try testing.expect((try a.feedLine("line2")) == .done);
    const out = try a.finish();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("line1\nline2", out);
}

test "Accumulator: triple-quote block" {
    var a = Accumulator.init(testing.allocator);
    defer a.deinit();
    try testing.expect((try a.feedLine("\"\"\"")) == .more);
    try testing.expect((try a.feedLine("first")) == .more);
    try testing.expect((try a.feedLine("second")) == .more);
    try testing.expect((try a.feedLine("\"\"\"")) == .done);
    const out = try a.finish();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("first\nsecond\n", out);
}

test "Accumulator: empty lines in block preserved" {
    var a = Accumulator.init(testing.allocator);
    defer a.deinit();
    _ = try a.feedLine("\"\"\"");
    _ = try a.feedLine("x");
    _ = try a.feedLine("");
    _ = try a.feedLine("y");
    _ = try a.feedLine("\"\"\"");
    const out = try a.finish();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("x\n\ny\n", out);
}

test "Accumulator: backslash inside block is literal" {
    var a = Accumulator.init(testing.allocator);
    defer a.deinit();
    _ = try a.feedLine("\"\"\"");
    _ = try a.feedLine("with \\ inside");
    _ = try a.feedLine("\"\"\"");
    const out = try a.finish();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("with \\ inside\n", out);
}

test "Accumulator: reset clears state" {
    var a = Accumulator.init(testing.allocator);
    defer a.deinit();
    _ = try a.feedLine("\"\"\"");
    _ = try a.feedLine("abandoned");
    a.reset();
    try testing.expect(a.in_block == false);
    try testing.expect((try a.feedLine("fresh")) == .done);
    const out = try a.finish();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("fresh", out);
}

test "Accumulator: trailing whitespace does not trigger continuation" {
    var a = Accumulator.init(testing.allocator);
    defer a.deinit();
    try testing.expect((try a.feedLine("no-cont   ")) == .done);
    const out = try a.finish();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("no-cont   ", out);
}
