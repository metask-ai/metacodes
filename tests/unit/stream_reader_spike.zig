//! M1.1 spike：验证 Zig 0.17-dev 的 std.Io.Reader.takeDelimiter 能支撑真流式 SSE。
//!
//! 目标：喂一段包含多个 SSE 事件的 bytes，用 fixed reader + takeDelimiter('\n')
//! 逐行消费，断言能按行拿到数据、跨 chunk 不丢字节、EOF 正确 null。
//!
//! 结论（如果 spike 通过）：M1.3 的 EventIterator 可以直接用 takeDelimiter，
//! 不需要自建 line buffer。
//!
//! 0.16 兼容风险：takeDelimiter 是 0.17-dev 的 API（std.Io 在 0.15→0.16→0.17 经历过
//! 多次重构）。若项目稳定到 0.16，可能需改为 readUntilDelimiter 或手写行累积。本文件
//! 把 API 入口集中在一处便于未来替换。

const std = @import("std");

/// 真流式 SSE 行解析器（spike 版，不导出为正式 API，给 M1.3 参考）。
pub const LineReader = struct {
    reader: *std.Io.Reader,

    /// 读下一行（不含 '\n'）。EOF 返回 null。
    pub fn next(self: *LineReader) error{ ReadFailed, StreamTooLong }!?[]const u8 {
        return self.reader.takeDelimiter('\n');
    }
};

// --------------------------------------------------------------------------
// Spike tests
// --------------------------------------------------------------------------

test "spike: fixed reader returns single line" {
    var reader = std.Io.Reader.fixed("hello\n");
    var lr = LineReader{ .reader = &reader };
    const line = (try lr.next()).?;
    try std.testing.expectEqualStrings("hello", line);
    try std.testing.expect(try lr.next() == null);
}

test "spike: fixed reader returns multiple lines" {
    var reader = std.Io.Reader.fixed("a\nbb\nccc\n");
    var lr = LineReader{ .reader = &reader };
    try std.testing.expectEqualStrings("a", (try lr.next()).?);
    try std.testing.expectEqualStrings("bb", (try lr.next()).?);
    try std.testing.expectEqualStrings("ccc", (try lr.next()).?);
    try std.testing.expect(try lr.next() == null);
}

test "spike: last line without trailing newline still returned" {
    var reader = std.Io.Reader.fixed("line1\nline2");
    var lr = LineReader{ .reader = &reader };
    try std.testing.expectEqualStrings("line1", (try lr.next()).?);
    try std.testing.expectEqualStrings("line2", (try lr.next()).?);
    try std.testing.expect(try lr.next() == null);
}

test "spike: empty input returns null immediately" {
    var reader = std.Io.Reader.fixed("");
    var lr = LineReader{ .reader = &reader };
    try std.testing.expect(try lr.next() == null);
}

test "spike: SSE-shape payload with blank separator lines" {
    // 真实 SSE：每个事件后面都有一个空行分隔
    const sse =
        "data: {\"type\":\"message_start\"}\n" ++
        "\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"hi\"}}\n" ++
        "\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n";
    var reader = std.Io.Reader.fixed(sse);
    var lr = LineReader{ .reader = &reader };

    var data_lines: usize = 0;
    var blank_lines: usize = 0;
    while (try lr.next()) |line| {
        if (line.len == 0) {
            blank_lines += 1;
        } else if (std.mem.startsWith(u8, line, "data: ")) {
            data_lines += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), data_lines);
    try std.testing.expectEqual(@as(usize, 3), blank_lines);
}

test "spike: empty line between two data lines preserved" {
    var reader = std.Io.Reader.fixed("a\n\nb\n");
    var lr = LineReader{ .reader = &reader };
    try std.testing.expectEqualStrings("a", (try lr.next()).?);
    try std.testing.expectEqualStrings("", (try lr.next()).?);
    try std.testing.expectEqualStrings("b", (try lr.next()).?);
    try std.testing.expect(try lr.next() == null);
}
