const std = @import("std");
const json_mod = @import("src/json.zig");

pub fn main() void {
    // 模拟 SSE 事件解析
    var parser = json_mod.SseParser{};
    
    // 测试 data 行
    const data_line = "data: {\"type\":\"message_start\"}\n";
    const parsed = parser.parseLine(data_line);
    std.debug.print("Parsed: {any}\n", .{parsed});
    
    // 测试 event 行（应该返回 null）
    const event_line = "event: message_start\n";
    const parsed2 = parser.parseLine(event_line);
    std.debug.print("Event line parsed: {any}\n", .{parsed2});
    
    // 测试 content_block_delta
    const delta_line = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n";
    const parsed3 = parser.parseLine(delta_line);
    std.debug.print("Delta parsed: {any}\n", .{parsed3});
    
    if (parsed3) |d| {
        const text = json_mod.extractTextDelta(d, std.heap.page_allocator) catch null;
        std.debug.print("Text delta: {any}\n", .{text});
    }
}
